const std = @import("std");
const simd = @import("simd.zig");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// CSV emitter for writing well-formed CSV data to a writer.
///
/// The Emitter handles automatic delimiter insertion between columns and rows,
/// proper quoting of fields containing special characters (commas, quotes, newlines),
/// and escaping of quotes within quoted fields according to RFC 4180.
///
/// Example usage:
/// ```zig
/// var emitter = Emitter.init(&writer);
///
/// try emitter.emit("Name");
/// try emitter.emit("Age");
/// emitter.next_row();
///
/// try emitter.emit("John Doe");
/// try emitter.emit("30");
/// emitter.next_row();
/// ```
pub const Emitter = struct {
    /// The writer to which CSV data will be written.
    writer: *Writer,

    /// When true, uses CRLF (\r\n) for line endings instead of LF (\n).
    /// Useful for Windows compatibility.
    use_crlf: bool = false,
    first_column: bool = true,
    first_row: bool = true,

    /// Creates a new CSV emitter that writes to the given writer.
    pub fn init(writer: *Writer) Emitter {
        return .{ .writer = writer };
    }

    /// Advances to the next row in the CSV output.
    /// Call this after emitting all columns for the current row.
    ///
    /// Example:
    /// ```zig
    /// try emitter.emit("column1");
    /// try emitter.emit("column2");
    /// emitter.next_row(); // Move to next row
    /// try emitter.emit("column1");
    /// try emitter.emit("column2");
    /// ```
    pub fn next_row(self: *Emitter) void {
        self.first_column = true;
    }

    /// Emits a quoted column value without escaping quotes in the input.
    ///
    /// WARNING: This function assumes the input data has already been properly escaped
    /// (i.e., any quotes have been doubled). If the input contains unescaped quotes,
    /// the output will be malformed CSV. Use this only when you know the data is
    /// already properly escaped for performance-critical scenarios.
    ///
    /// Parameters:
    ///   - column: The pre-escaped column data to emit (quotes should already be doubled).
    pub fn emit_quoted_assume_escaped(self: *Emitter, column: []const u8) Writer.Error!void {
        try self.emit_delim();
        try self.writer.writeByte('"');
        try self.writer.writeAll(column);
        try self.writer.writeByte('"');
    }

    /// Emits a quoted column value, automatically escaping any quotes in the input.
    ///
    /// This function wraps the column value in quotes and escapes any quote characters
    /// by doubling them (e.g., " becomes ""). Use this when the column contains special
    /// characters or when you want to ensure proper escaping.
    ///
    /// Parameters:
    ///   - column: The column data to emit (quotes will be automatically escaped).
    pub fn emit_quoted(self: *Emitter, column: []const u8) Writer.Error!void {
        try self.emit_delim();
        try self.writer.writeByte('"');
        try self.write_unescaped_data(column);
        try self.writer.writeByte('"');
    }

    /// Emits an unquoted column value.
    ///
    /// WARNING: This function does not check if the column contains special characters
    /// (commas, quotes, newlines). If the input contains any of these, the output will
    /// be malformed CSV. Use this only when you know the data does not contain special
    /// characters and you want maximum performance.
    ///
    /// Parameters:
    ///   - column: The column data to emit without quotes.
    pub fn emit_no_quotes(self: *Emitter, column: []const u8) Writer.Error!void {
        try self.emit_delim();
        try self.writer.writeAll(column);
    }

    /// Emits a column value with automatic quoting when necessary.
    ///
    /// This is the recommended method for emitting CSV columns. It automatically
    /// determines whether the value needs to be quoted based on whether it contains
    /// special characters (commas, quotes, newlines). If quoting is needed, quotes
    /// in the value are automatically escaped.
    ///
    /// Parameters:
    ///   - column: The column data to emit.
    ///
    /// Example:
    /// ```zig
    /// try emitter.emit("simple value");      // Written as: simple value
    /// try emitter.emit("value, with comma"); // Written as: "value, with comma"
    /// try emitter.emit("value with \"quote\""); // Written as: "value with ""quote"""
    /// ```
    pub fn emit(self: *Emitter, column: []const u8) Writer.Error!void {
        if (contains_delim(column)) {
            try self.emit_quoted(column);
        } else {
            try self.emit_no_quotes(column);
        }
    }

    inline fn contains_delim(data: []const u8) bool {
        const delim_map: [256]bool = comptime blk: {
            var a = [_]bool{false} ** 256;
            a['\n'] = true;
            a[','] = true;
            a['"'] = true;
            break :blk a;
        };

        var start: usize = 0;
        if (simd.suggestVectorLength()) |len| {
            const Vec = @Vector(len, u8);
            while (start + len < data.len) : (start += len) {
                const slice: Vec = data[start..][0..len].*;
                const quote_mask: Vec = @splat('"');
                const newline_mask: Vec = @splat('\n');
                const comma_mask: Vec = @splat(',');
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
            if (std.mem.indexOfScalarPos(u8, data, index, '"')) |idx| {
                try self.writer.writeAll(data[index..idx]);
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
            if (self.first_row) {
                self.first_row = false;
            } else {
                @branchHint(.likely);
                if (self.use_crlf)
                    try self.writer.writeAll("\r\n")
                else
                    try self.writer.writeByte('\n');
            }
        } else {
            try self.writer.writeByte(',');
        }
    }
};
