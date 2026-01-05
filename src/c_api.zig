const std = @import("std");
const csvz = @import("root.zig");

const c = @cImport({
    @cInclude("stdio.h");
});

const FileSource = struct {
    handle: std.fs.File,
    reader: std.fs.File.Reader,
};

const ReadStatus = enum(c_int) {
    OK,
    EOF,
    Error,
};

const ReadResult = extern struct {
    bytes_read: usize,
    status: ReadStatus,
};

const CallbackSource = struct {
    context: *anyopaque,
    callback: Fn,
    interface: std.Io.Reader,

    const Fn = *const fn (*anyopaque, [*]u8, usize) callconv(.c) ReadResult;

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        var source: *CallbackSource = @fieldParentPtr("interface", r);
        const data = limit.slice(try w.writableSliceGreedy(1));
        const result = source.callback(source.context, data.ptr, data.len);
        if (result.bytes_read == 0 or result.status == .EOF) {
            @branchHint(.unlikely);
            return error.EndOfStream;
        } else if (result.status == .Error) {
            @branchHint(.unlikely);
            return error.ReadFailed;
        }
        w.advance(result.bytes_read);
        return result.bytes_read;
    }

    fn init(ctx: *anyopaque, cb: Fn, buffer: []u8) CallbackSource {
        return .{
            .context = ctx,
            .callback = cb,
            .interface = std.Io.Reader{
                .buffer = buffer,
                .seek = 0,
                .end = 0,
                .vtable = &.{
                    .stream = CallbackSource.stream,
                },
            },
        };
    }
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
        callback: CallbackSource,
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
    last_error = .NoError;
    return it;
}

export fn csvz_iter_from_fd(stream: *c.FILE, buffer: [*]u8, len: usize) callconv(.c) ?*Iterator {
    var it: *Iterator = std.heap.c_allocator.create(Iterator) catch {
        last_error = .OOM;
        return null;
    };
    const file: std.fs.File = .{ .handle = c.fileno(stream) };
    it.source.fd = .{ .handle = file, .reader = file.reader(buffer[0..len]) };
    it.iterator = csvz.Iterator.init(&it.source.fd.reader.interface);
    last_error = .NoError;
    return it;
}

export fn csvz_iter_from_bytes(buffer: [*]u8, len: usize) callconv(.c) ?*Iterator {
    var it: *Iterator = std.heap.c_allocator.create(Iterator) catch {
        last_error = .OOM;
        return null;
    };
    it.source.fixed_buffer = std.Io.Reader.fixed(buffer[0..len]);
    it.iterator = csvz.Iterator.init(&it.source.fixed_buffer);
    last_error = .NoError;
    return it;
}

export fn csvz_iter_from_callback(
    ctx: *anyopaque,
    cb: CallbackSource.Fn,
    buffer: [*]u8,
    len: usize,
) callconv(.c) ?*Iterator {
    var it: *Iterator = std.heap.c_allocator.create(Iterator) catch {
        last_error = .OOM;
        return null;
    };
    it.source.callback = .init(ctx, cb, buffer[0..len]);
    it.iterator = csvz.Iterator.init(&it.source.callback.interface);
    last_error = .NoError;
    return it;
}

export fn csvz_iter_next(it: *Iterator, field: *Field) callconv(.c) Error {
    const item = it.iterator.next() catch |err| {
        @branchHint(.unlikely);
        switch (err) {
            csvz.Iterator.Error.EOF => return Error.EOF,
            csvz.Iterator.Error.FieldTooLong => return Error.FieldTooLong,
            csvz.Iterator.Error.InvalidQuotes => return Error.InvalidQuotes,
            csvz.Iterator.Error.ReadFailed => return Error.ReadFailed,
        }
    };
    field.data = item.data.ptr;
    field.len = item.data.len;
    field.last_column = item.last_column;
    field.needs_unescape = item.needs_unescape;
    return .NoError;
}

export fn csvz_unescape_in_place(data: [*]u8, len: usize) usize {
    const it = @import("iterator.zig");
    return it.unescapeInPlace('"', data[0..len]).len;
}

export fn csvz_iter_free(it: *Iterator) callconv(.c) void {
    switch (it.source) {
        .file => |f| f.handle.close(),
        else => {},
    }
    std.heap.c_allocator.destroy(it);
}

export fn csvz_err() callconv(.c) Error {
    return last_error;
}
