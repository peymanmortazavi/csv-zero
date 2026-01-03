const std = @import("std");
const csvz = @import("root.zig");

const FileSource = struct {
    handle: std.fs.File,
    reader: std.fs.File.Reader,
};

const Field = extern struct {
    data: [*]u8,
    len: usize,
    last_column: bool,
    needs_unescape: bool,
};

const Error = enum(c_int) {
    NoError,
    OOM,
    FieldTooLong,
    EOF,
    InvalidQuotes,
    ReadFailed,
    OpenError,
};

threadlocal var last_error: Error = .NoError;

const Iterator = struct {
    iterator: csvz.Iterator,
    source: union(enum) {
        file: FileSource,
        fd: FileSource,
        fixed_buffer: std.Io.Reader,
    },
};

export fn csvz_iter_from_file(filename: [*:0]const u8, buffer: [*]u8, len: usize) callconv(.c) ?*Iterator {
    var it: *Iterator = std.heap.c_allocator.create(Iterator) catch {
        last_error = .OOM;
        return null;
    };
    const file = std.fs.cwd().openFileZ(filename, .{ .mode = .read_only }) catch {
        last_error = .OpenError;
        return null;
    };
    it.source.file = .{ .handle = file, .reader = file.reader(buffer[0..len]) };
    it.iterator = csvz.Iterator.init(&it.source.file.reader.interface);
    return it;
}

export fn csvz_iter_next(it: *Iterator, field: *Field) callconv(.c) Error {
    const item = it.iterator.next() catch |err| switch (err) {
        csvz.Iterator.Error.EOF => return Error.EOF,
        csvz.Iterator.Error.FieldTooLong => return Error.FieldTooLong,
        csvz.Iterator.Error.InvalidQuotes => return Error.InvalidQuotes,
        csvz.Iterator.Error.ReadFailed => return Error.ReadFailed,
    };
    field.data = item.data.ptr;
    field.len = item.data.len;
    field.last_column = item.last_column;
    field.needs_unescape = item.needs_unescape;
    return .NoError;
}

export fn csvz_iter_free(it: *Iterator) callconv(.c) void {
    switch (it.source) {
        .file => |f| f.handle.close(),
        else => {},
    }
    std.heap.c_allocator.destroy(it);
}

export fn csvz_iter_count(it: *Iterator) callconv(.c) c_ulong {
    var count: c_ulong = 0;
    while (it.iterator.next()) |_| {
        count += 1;
    } else |_| return count;
    return count;
}

export fn csvz_err() callconv(.c) Error {
    return last_error;
}
