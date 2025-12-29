const std = @import("std");
const simd = @import("simd.zig");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Dialect = struct {
    quote: u8 = '"',
    delimiter: u8 = ',',
    vector_length: ?comptime_int = simd.suggestVectorLength(),
};

pub fn Csv(comptime dialect: Dialect) type {
    return struct {
        reader: *std.Io.Reader,
        needs_escape: bool = false,
        quote_pending: bool = false,
        vector: Bitmask = if (use_vectors) 0 else {},
        vector_offset: if (use_vectors) usize else void = if (use_vectors) 0 else {},

        const Self = @This();
        const Newline = '\n';
        const CarriageReturn = '\r';

        const Bitmask = if (dialect.vector_length) |len| std.meta.Int(.unsigned, len) else void;
        const Vector = if (dialect.vector_length) |len| @Vector(len, u8) else void;

        const QuoteMask: Vector = @splat(dialect.quote);
        const DelimiterMask: Vector = @splat(dialect.delimiter);
        const NewLineMask: Vector = @splat(Newline);

        const use_vectors = dialect.vector_length != null;

        const is_delim = blk: {
            var t = [_]bool{false} ** 256;
            t[dialect.delimiter] = true;
            t[dialect.quote] = true;
            t[Newline] = true;
            break :blk t;
        };

        pub const Error = error{ ReadFailed, InvalidQuotes, FieldTooLong, EOF };

        const QuotedRegion = struct {
            end: usize,
            last_column: bool,
        };

        /// Field represents a CSV-field.
        /// Its contents are guaranteed to remain valid until next call to the `next()` function.
        pub const Field = struct {
            /// the raw column data which is a slice of the buffer in the reader.
            /// this may need escaping, needs_escape holds whether or not escaping is necessary.
            /// use unescaped to get the unescaped value regardless.
            data: []u8,
            /// indicates whether or not this is the last column in the current row.
            last_column: bool,
            /// indicates whether or not escaped double quotes are present in the column.
            needs_escape: bool = false,

            pub fn eql(self: *const Field, other: Field) bool {
                return std.mem.eql(u8, self.data, other.data) and
                    self.last_column == other.last_column and
                    self.needs_escape == self.needs_escape;
            }

            /// remove the escape characters in the text if necessary and return the column.
            /// this method has a side-effect and will overwrite the column data.
            pub fn unescaped(self: *Field) []u8 {
                if (self.needs_escape) {
                    self.needs_escape = false;
                    self.data = unescapeInPlace(dialect.quote, self.data);
                    return self.data;
                }

                return self.data;
            }

            fn fmt(self: *const Field, writer: *Writer) Writer.Error!void {
                try writer.print("{s} [last col={}]", .{ self.data, self.last_column });
            }

            fn new(ally: Allocator, col: []const u8, last_col: bool, needs_escape: bool) Allocator.Error!Field {
                const c = try ally.dupe(u8, col);
                return .{ .data = c, .last_column = last_col, .needs_escape = needs_escape };
            }
        };

        pub fn init(reader: *std.Io.Reader) Self {
            return .{ .reader = reader };
        }

        /// finds the end of the quoted region (assuming the first double quote is alerady consumed).
        /// it only returns the quoted region is the character after the double quote is known. If the double
        /// quote is the very last character in the buffer and in the file, then it needs to be handled outside of this
        /// function.
        inline fn findQuotedRegion(self: *Self, start_index: usize) Error!?QuotedRegion {
            var i = start_index - @intFromBool(self.quote_pending);
            self.quote_pending = false;
            const data = self.reader.buffer[0..self.reader.end];
            var r = self.reader;

            while (self.nextDelimPos(i)) |idx| {
                if (data[idx] == dialect.quote) {
                    if (idx + 1 == data.len) {
                        @branchHint(.unlikely);
                        self.quote_pending = true;
                        return null;
                    }

                    switch (data[idx + 1]) {
                        dialect.quote => {
                            self.needs_escape = true;
                            self.skipNextDelim();
                            i = idx + 2;
                        },
                        dialect.delimiter => {
                            self.skipNextDelim();
                            r.toss(1 + 1 + idx - r.seek); // toss ',' in addition to "
                            return .{ .end = idx, .last_column = false };
                        },
                        Newline => {
                            self.skipNextDelim();
                            r.toss(1 + 1 + idx - r.seek); // toss '\n' in addition to "
                            return .{ .end = idx, .last_column = true };
                        },
                        CarriageReturn => {
                            self.skipNextDelim();
                            r.toss(2 + 1 + idx - r.seek); // toss '\r' and '\n' in addition to "
                            return .{ .end = idx, .last_column = true };
                        },
                        else => {
                            @branchHint(.cold);
                            return error.InvalidQuotes;
                        },
                    }
                } else {
                    if (idx + 1 == data.len) {
                        @branchHint(.unlikely);
                        return null;
                    }
                    i = idx + 1;
                }
            }

            return null;
        }

        fn nextQuotedRegion(self: *Self) Error!Field {
            self.reader.toss(1);
            self.needs_escape = false;
            var r = self.reader;
            {
                const seek = r.seek;
                if (try self.findQuotedRegion(seek)) |region| {
                    return .{
                        .data = r.buffer[seek..region.end],
                        .last_column = region.last_column,
                        .needs_escape = self.needs_escape,
                    };
                }
            }

            while (true) {
                const content_len = r.end - r.seek;
                if (r.buffer.len - content_len == 0) break;
                Reader.fillMore(r) catch |e| switch (e) {
                    Reader.Error.EndOfStream => {
                        const remaining = r.buffered();
                        if (remaining.len == 0) return Error.InvalidQuotes;
                        const seek = r.seek;
                        // NB: findQuotedRegion only returns if after the double quote is another character.
                        // if it does not return, it means the remaining buffer MUST end with a double quote.
                        if (try self.findQuotedRegion(seek + content_len)) |region| {
                            return .{
                                .data = r.buffer[seek..region.end],
                                .last_column = region.last_column,
                                .needs_escape = self.needs_escape,
                            };
                        }
                        r.toss(remaining.len);
                        if (remaining[remaining.len - 1] != dialect.quote) {
                            @branchHint(.unlikely);
                            return Error.InvalidQuotes;
                        }
                        return .{
                            .data = remaining[0 .. remaining.len - 1],
                            .last_column = true,
                            .needs_escape = self.needs_escape,
                        };
                    },
                    else => |err| return err,
                };
                const seek = r.seek;
                if (try self.findQuotedRegion(seek + content_len)) |region| {
                    return .{
                        .data = r.buffer[seek..region.end],
                        .last_column = region.last_column,
                        .needs_escape = self.needs_escape,
                    };
                }
            }

            var failing_writer = Writer.failing;
            while (r.vtable.stream(r, &failing_writer, .limited(1))) |n| {
                std.debug.assert(n == 0);
            } else |err| switch (err) {
                error.WriteFailed => return Error.FieldTooLong,
                error.ReadFailed => return Error.ReadFailed,
                error.EndOfStream => {
                    var remaining = r.buffered();
                    if (remaining.len == 0) return Error.InvalidQuotes;
                    r.toss(remaining.len);
                    if (remaining[remaining.len - 1] != dialect.quote) return Error.InvalidQuotes;
                    remaining.len -= 1;
                    return .{
                        .data = remaining,
                        .last_column = true,
                        .needs_escape = self.needs_escape,
                    };
                },
            }
        }

        inline fn handleBoundary(self: *Self, delim: u8, seek: usize, end: usize) Error!Field {
            const prev_is_cr = @intFromBool((end != 0) and (self.reader.buffer[end - 1] == CarriageReturn));
            const is_newline = @intFromBool(delim == Newline);
            const trim_cr = prev_is_cr & is_newline;

            self.reader.toss(1 + end - seek);
            return .{
                .data = self.reader.buffer[seek .. end - trim_cr],
                .last_column = is_newline != 0,
            };
        }

        pub fn next(self: *Self) Error!Field {
            var r = self.reader;
            {
                const seek = r.seek;
                if (self.nextDelimPos(seek)) |end| {
                    @branchHint(.likely);
                    const delim = r.buffer[end];
                    if (delim == dialect.quote) return self.nextQuotedRegion();

                    return self.handleBoundary(delim, seek, end);
                }
            }

            while (true) {
                const content_len = r.end - r.seek;
                if (r.buffer.len - content_len == 0) break;
                Reader.fillMore(r) catch |e| switch (e) {
                    Reader.Error.EndOfStream => {
                        const remaining = r.buffered();
                        if (remaining.len == 0) return error.EOF;
                        r.toss(remaining.len);
                        return .{ .data = remaining, .last_column = true };
                    },
                    else => |err| return err,
                };
                const seek = r.seek;
                if (self.nextDelimPos(seek + content_len)) |end| {
                    const delim = r.buffer[end];
                    if (delim == dialect.quote) return self.nextQuotedRegion();

                    return self.handleBoundary(delim, seek, end);
                }
            }

            var failing_writer = Writer.failing;
            while (r.vtable.stream(r, &failing_writer, .limited(1))) |n| {
                std.debug.assert(n == 0);
            } else |err| switch (err) {
                error.WriteFailed => return Error.FieldTooLong,
                error.ReadFailed => |e| return e,
                error.EndOfStream => {
                    const remaining = r.buffer[r.seek..r.end];
                    if (remaining.len == 0) return error.EOF;
                    r.toss(remaining.len);
                    return .{ .data = remaining, .last_column = true };
                },
            }
        }

        inline fn skipNextDelim(self: *Self) void {
            if (use_vectors) {
                self.vector &= self.vector -% 1;
            }
        }

        inline fn nextDelimPos(self: *Self, start_pos: usize) ?usize {
            const r = self.reader;
            if (use_vectors) {
                if (self.vector != 0) {
                    const idx = @ctz(self.vector);
                    self.vector &= self.vector - 1;
                    return idx + self.vector_offset;
                }
            }

            var i: usize = start_pos;

            if (dialect.vector_length) |vector_len| {
                while (i + vector_len < r.end) : (i += vector_len) {
                    const input: Vector = r.buffer[i..r.end][0..vector_len].*;
                    const q = input == QuoteMask;
                    const comma = input == DelimiterMask;
                    const newline = input == NewLineMask;
                    const delim = (comma | q | newline);
                    self.vector = @bitCast(delim);
                    if (self.vector != 0) {
                        const idx = @ctz(self.vector);
                        self.vector_offset = i;
                        self.vector &= self.vector - 1;
                        return i + idx;
                    }
                }
            }

            while (i < r.end) : (i += 1) {
                if (is_delim[r.buffer[i]]) return i;
            }

            return null;
        }
    };
}

fn unescapeInPlace(comptime quote: u8, data: []u8) []u8 {
    var search_cursor: usize = 0;
    var write_cursor: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfScalarPos(u8, data, search_cursor, quote)) |pos| {
        if (data.len <= pos + 1 or data[pos + 1] != quote) {
            @branchHint(.unlikely);
            search_cursor = pos + 1;
            continue;
        }
        if (count == 0) {
            write_cursor = pos + 1;
        } else {
            const slice = data[search_cursor .. pos + 1];
            @memmove(data[write_cursor..][0..slice.len], slice);
            write_cursor += slice.len;
        }
        search_cursor = pos + 2;
        count += 1;
    } else {
        @memmove(data[write_cursor .. data.len - count], data[search_cursor..]);
        return data[0 .. data.len - count];
    }
}
