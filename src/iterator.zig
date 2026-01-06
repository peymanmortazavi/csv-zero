const std = @import("std");
const simd = @import("simd.zig");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// Configuration for CSV parsing behavior.
///
/// Use this to customize how CSV data is parsed, including the quote character,
/// field delimiter, and SIMD vector length for performance optimization.
///
/// Example:
///     const CustomIterator = Csv(.{.quote = '\'', .delimiter = ';'});
pub const Dialect = struct {
    /// Character used to quote fields containing special characters (default: '"')
    quote: u8 = '"',
    /// Character used to separate fields (default: ',')
    delimiter: u8 = ',',
    /// SIMD vector length for optimized parsing. Set to null to disable SIMD.
    /// By default, uses the optimal vector length for your platform.
    vector_length: ?comptime_int = simd.suggestVectorLength(),
};

/// Creates a CSV iterator type configured with the specified dialect.
///
/// This is a compile-time function that returns a type specialized for itearting
/// CSV fields according to the provided dialect configuration. The returned type
/// includes SIMD optimizations when vector_length is set.
///
/// Basic usage:
/// ```zig
///     const CsvParser = Csv(.{}); // Use default dialect
///     var iterator = CsvParser.init(&reader);
///
///     while (true) {
///         const col = csvit.next() catch |err| switch (err) {
///             csvz.Iterator.Error.EOF => break,
///             else => |e| return e,
///         };
///         // col.data <- raw value which might include unescaped quotes.
///         // col.unescaped() <- note that this function has a side-effect.
///         std.debug.print("col: {s}, last? {}\n", .{ col.unescaped(), col.last_column });
///     }
/// ```
pub fn Csv(comptime dialect: Dialect) type {
    return struct {
        reader: *std.Io.Reader,
        needs_unescape: bool = false,
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

        /// Errors that can occur during CSV parsing.
        ///
        /// - ReadFailed: The underlying reader encountered an error
        /// - InvalidQuotes: Malformed quoted fields (e.g., unmatched quotes)
        /// - FieldTooLong: A field exceeded the reader's buffer capacity
        /// - EOF: Reached the end of the CSV file (not an error condition in normal use)
        pub const Error = error{ ReadFailed, InvalidQuotes, FieldTooLong, EOF };

        const QuotedRegion = struct {
            /// position of the matching quote character in the buffer.
            end: usize,
            /// whether or not quoted region is the last column in the row.
            last_column: bool,
        };

        /// Represents a single CSV field.
        ///
        /// Fields are returned by the `next()` method and remain valid only until
        /// the next call to `next()`. If you need to keep field data longer, copy it.
        ///
        /// The `data` field contains the raw field content, which may include escaped
        /// quotes (e.g., `""` representing a single `"`). Use `unescaped()` to get
        /// the final value with escape sequences resolved.
        pub const Field = struct {
            /// Raw field data as a slice of the reader's buffer.
            /// Contains escaped quotes if `needs_unescape` is true.
            /// For the final value, use `unescaped()` instead.
            data: []u8,
            /// True if this field is the last column in the current row.
            /// Use this to detect row boundaries when iterating through fields.
            last_column: bool,
            /// True if the field contains escaped double quotes (e.g., `""` for `"`).
            /// When true, call `unescaped()` to remove the escape characters.
            needs_unescape: bool = false,

            /// Compares two fields for equality based on data, last_column, and needs_unescape.
            pub fn eql(self: *const Field, other: Field) bool {
                return std.mem.eql(u8, self.data, other.data) and
                    self.last_column == other.last_column and
                    self.needs_unescape == self.needs_unescape;
            }

            /// Returns the unescaped field data with escape sequences removed.
            ///
            /// This method removes CSV escape sequences in-place (e.g., converts `""` to `"`).
            /// After calling this method, `needs_unescape` is set to false and `data` contains
            /// the unescaped result. Subsequent calls return the same unescaped data.
            ///
            /// Note: This modifies the field in-place by overwriting the internal buffer.
            pub fn unescaped(self: *Field) []u8 {
                if (self.needs_unescape) {
                    self.needs_unescape = false;
                    self.data = unescapeInPlace(dialect.quote, self.data);
                    return self.data;
                }

                return self.data;
            }

            fn fmt(self: *const Field, writer: *Writer) Writer.Error!void {
                try writer.print("{s} [last col={}]", .{ self.data, self.last_column });
            }

            fn new(ally: Allocator, col: []const u8, last_col: bool, needs_unescape: bool) Allocator.Error!Field {
                const c = try ally.dupe(u8, col);
                return .{ .data = c, .last_column = last_col, .needs_unescape = needs_unescape };
            }
        };

        /// Initializes a CSV iterator with the given reader.
        ///
        /// The reader must remain valid for the lifetime of the iterator.
        /// The iterator takes a pointer to the reader and uses its internal
        /// buffer for zero-copy field access.
        ///
        /// Example:
        /// ```zig
        /// var reader = std.Io.Reader.fixed(...);
        /// var it = Iterator.init(&reader);
        /// ```
        pub fn init(reader: *std.Io.Reader) Self {
            return .{ .reader = reader };
        }

        /// finds the end of the quoted region (assuming the first double quote is alerady consumed).
        /// it only returns the quoted region if the character after the double quote is known. If the double
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
                            self.needs_unescape = true;
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
                            if (idx + 2 == data.len) {
                                @branchHint(.unlikely);
                                self.quote_pending = true;
                                return null;
                            }
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
            self.needs_unescape = false;
            var r = self.reader;
            {
                const seek = r.seek;
                if (try self.findQuotedRegion(seek)) |region| {
                    return .{
                        .data = r.buffer[seek..region.end],
                        .last_column = region.last_column,
                        .needs_unescape = self.needs_unescape,
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
                        if (try self.findQuotedRegion(seek + content_len)) |region| {
                            return .{
                                .data = r.buffer[seek..region.end],
                                .last_column = region.last_column,
                                .needs_unescape = self.needs_unescape,
                            };
                        }
                        r.toss(remaining.len);
                        var end = remaining.len - 1;
                        if (end > 0 and remaining[end] == Newline) end -= 1;
                        if (end > 0 and remaining[end] == CarriageReturn) end -= 1;
                        // NB: findQuotedRegion only returns if after the double quote is another character.
                        // if it does not return, it means the remaining buffer MUST end with a double quote.
                        if (remaining[end] != dialect.quote) {
                            @branchHint(.unlikely);
                            return Error.InvalidQuotes;
                        }
                        return .{
                            .data = remaining[0..end],
                            .last_column = true,
                            .needs_unescape = self.needs_unescape,
                        };
                    },
                    else => |err| return err,
                };
                const seek = r.seek;
                if (try self.findQuotedRegion(seek + content_len)) |region| {
                    return .{
                        .data = r.buffer[seek..region.end],
                        .last_column = region.last_column,
                        .needs_unescape = self.needs_unescape,
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
                        .needs_unescape = self.needs_unescape,
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

        /// Advances the iterator and returns the next CSV field.
        ///
        /// This method is the primary way to iterate through CSV data. Each call returns
        /// one field, and you can detect row boundaries using the `last_column` flag on
        /// the returned Field.
        ///
        /// The returned Field's data is a slice into the reader's internal buffer, making
        /// this a zero-copy operation. The data remains valid only until the next call to
        /// `next()`, so copy it if you need to retain it longer.
        ///
        /// When the end of the file is reached, returns `error.EOF`, which is the normal
        /// termination condition (not an error in typical usage).
        ///
        /// Example iterating through all fields:
        /// ```zig
        /// while (true) {
        ///     var field = it.next() catch |err| switch (err) {
        ///         error.EOF => break,
        ///         else => |e| // handle the err
        ///     };
        ///     const value = field.unescaped();
        ///     std.debug.print("{s}", .{value});
        ///     if (field.last_column) {
        ///         std.debug.print("\n", .{}); // End of row
        ///     } else {
        ///         std.debug.print(",", .{});
        ///     }
        /// }
        /// ```
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

/// Removes escape sequences from a string slice in-place by overwriting the data.
/// Returns a smaller slice containing the unescaped string content.
pub fn unescapeInPlace(comptime quote: u8, data: []u8) []u8 {
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
