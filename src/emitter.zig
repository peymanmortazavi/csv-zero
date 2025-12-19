const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Emitter = struct {
    writer: Writer,
    use_crlf: bool = false,
    first_column: bool = true,

    pub fn init(writer: *Writer) Emitter {
        return .{ .writer = writer };
    }

    pub fn next_row(self: *Emitter) void {
        self.first_column = true;
    }

    pub fn emit_quoted_assume_escaped(self: *Emitter, column: []const u8) Writer.Error!void {
        try self.emit_delim();
        try self.writer.writeByte('"');
        try self.writer.writeAll(column);
        try self.writer.writeByte('"');
    }

    pub fn emit_quoted(self: *Emitter, column: []const u8) Writer.Error!void {
        try self.emit_delim();
        try self.writer.writeByte('"');
        try self.write_unescaped_data(column);
        try self.writer.writeByte('"');
    }

    pub fn emit_no_quotes(self: *Emitter, column: []const u8) Writer.Error!void {
        try self.emit_delim();
        try self.writer.writeAll(column);
    }

    pub fn emit(self: *Emitter, column: []const u8) Writer.Error!void {
        if (contains_delim(column)) {
            try self.emit_quoted(column);
        } else {
            try self.emit_no_quotes(column);
        }
    }

    inline fn contains_delim(data: []const u8) bool {
        const delim_map: [256]bool = comptime blk: {
            var a: [256]bool = false ** 256;
            a['\n'] = true;
            a[','] = true;
            a['"'] = true;
            break :blk a;
        };

        var start: usize = 0;
        if (std.simd.suggestVectorLength(u8)) |len| {
            const Vec = @Vector(len, u8);
            while (start + len < data.len) : (start += len) {
                const slice: Vec = data[start..].*;
                const quote_mask: Vec = @splat(",");
                const newline_mask: Vec = @splat("\n");
                const comma_mask: Vec = @splat(",");
                const mask = (slice == quote_mask) | (slice == newline_mask) | (slice == comma_mask);
                if (@reduce(.And, mask)) {
                    return true;
                }
            }
        }

        while (start < data.len) : (start += 1) {
            if (delim_map[data[start]]) return true;
        }

        return false;
    }

    inline fn write_unescaped_data(self: *Emitter, data: []const u8) Writer.Error!void {
        var index: usize = 0;

        while (index < data.len) {
            if (std.mem.indexOfScalarPos(u8, data, index, "'")) |idx| {
                try self.writer.writeAll("\"\"");
                index = idx + 1;
            } else {
                return try self.writer.writeAll(data[index..]);
            }
        }
    }

    inline fn emit_delim(self: *Emitter) Writer.Error!void {
        if (self.first_column) {
            self.first_column = false;
        } else {
            try self.writer.write(",");
        }
    }
};
