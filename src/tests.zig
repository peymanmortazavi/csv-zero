const std = @import("std");
const csvz = @import("root.zig");

const string = []const u8;
const Columns = []const string;
const Table = []const Columns;

const IterateTestCase = struct {
    path: string,
    expected_error: ?ErrorExpectation = null,
    expected_table: Table,
    buffer_size: usize = 64,

    const ErrorExpectation = struct {
        err: csvz.Iterator.Error,
        row: usize,
        col: usize,
    };

    fn expectedErrAt(self: *const IterateTestCase, row: usize, col: usize) ?ErrorExpectation {
        const info = self.expected_error orelse return null;
        if (info.row == row and info.col == col) return info;
        return null;
    }

    fn last_row(self: *const IterateTestCase) usize {
        return if (self.expected_table.len == 0) 0 else self.expected_table.len - 1;
    }

    fn last_col(self: *const IterateTestCase) usize {
        if (self.expected_table.len == 0) return 0;
        const lr = self.expected_table.len - 1;
        const len = self.expected_table[lr].len;
        return if (len == 0) 0 else len - 1;
    }

    fn checkLastErr(self: *const IterateTestCase, received_err: csvz.Iterator.Error) !void {
        const expected = self.expected_error orelse {
            std.debug.print(
                "Unexpected error {s}",
                .{@errorName(received_err)},
            );
            return error.UnexpectedError;
        };
        if (expected.err != received_err) {
            std.debug.print(
                "Expected err {s} but received err {s}",
                .{ @errorName(expected.err), @errorName(received_err) },
            );
            return error.MismatchingErrors;
        }
    }

    fn expectNoLastErr(self: *const IterateTestCase) !void {
        const err = self.expected_error orelse return;
        std.debug.print(
            "Expected error {s} but received none.",
            .{@errorName(err.err)},
        );
        return error.UnexpectedError;
    }

    fn checkErr(self: *const IterateTestCase, received_err: csvz.Iterator.Error, row: usize, col: usize) !void {
        const expected = self.expectedErrAt(row, col) orelse {
            std.debug.print(
                "Unexpected error {s} at row={d} col={d}",
                .{ @errorName(received_err), row, col },
            );
            return error.UnexpectedError;
        };
        if (expected.err != received_err) {
            std.debug.print(
                "Expected err {s} but received err {s} at row={d}, col={d}",
                .{ @errorName(expected.err), @errorName(received_err), row, col },
            );
            return error.MismatchingErrors;
        }
    }

    fn expectNoErr(self: *const IterateTestCase, row: usize, col: usize) !void {
        const err = self.expectedErrAt(row, col) orelse return;
        std.debug.print(
            "Expected error {s} at row={d} col={d} but received none.",
            .{ @errorName(err.err), err.row, err.col },
        );
        return error.UnexpectedError;
    }

    fn run(tt: *const @This(), it: *csvz.Iterator) !void {
        // for each column in test case, we should see a value in the same row in the iterator.
        for (tt.expected_table, 0..) |row, row_index| {
            for (row, 0..) |col, col_index| {
                var received = it.next() catch |err| {
                    return try tt.checkErr(err, row_index, col_index);
                };
                try tt.expectNoErr(row_index, col_index);
                const data = received.unescaped();
                const last_column = col_index == row.len - 1;
                if (!std.mem.eql(u8, col, data) or received.last_column != last_column) {
                    std.debug.print(
                        "==== Expected Column =====\ndata:{s}\nlast_column: {}\n\n",
                        .{ col, last_column },
                    );
                    std.debug.print(
                        "==== Received Column =====\ndata:{s}\nlast_column: {}\n",
                        .{ data, received.last_column },
                    );
                    std.debug.print("row={d}, col={d}\n\n", .{ row_index, col_index });
                    return error.MismatchingColumns;
                }
            }
        }

        // ensure it has no more rows
        var col = it.next() catch |err| switch (err) {
            csvz.Iterator.Error.EOF => return,
            else => |e| {
                return try tt.checkLastErr(e);
            },
        };
        try tt.expectNoLastErr();
        std.debug.print(
            "Unexpected extra col:\ndata:{s}\nlast_column:{}\n\n",
            .{ col.unescaped(), col.last_column },
        );
        return error.UnexpectedExtraCol;
    }
};

test "iterator" {
    const test_cases = [_]IterateTestCase{
        .{
            .path = "simple_single_row.csv",
            .expected_error = null,
            .expected_table = &.{&.{ "a", "b", "c" }},
        },
        .{
            .path = "multiple_rows.csv",
            .expected_error = null,
            .expected_table = &.{
                &.{ "a", "b", "c" },
                &.{ "hello", "world", " leading and trailing spaces are fine " },
            },
        },
        .{
            .path = "multiple_rows_crlf.csv",
            .expected_error = null,
            .expected_table = &.{
                &.{ "a", "b", "c" },
                &.{ "hello", "world", " leading and trailing spaces are fine " },
            },
        },
        .{
            .path = "empty_file.csv",
            .expected_error = null,
            .expected_table = &.{},
        },
        .{
            .path = "simple_no_lf.csv",
            .expected_error = null,
            .expected_table = &.{
                &.{ "a", "b", "c" },
                &.{ "e", "f", "g" },
            },
        },
        .{
            .path = "quotes.csv",
            .expected_error = null,
            .expected_table = &.{
                &.{ "a", "b", "c" },
                &.{ "hello", "world", " leading and trailing spaces are fine " },
            },
        },
        .{
            .path = "quotes_no_lf.csv",
            .expected_error = null,
            .expected_table = &.{
                &.{ "a", "b", "c" },
                &.{ "hello", "world", " leading and trailing spaces are fine " },
            },
        },
        .{
            .path = "quotes_crlf.csv",
            .expected_error = null,
            .expected_table = &.{
                &.{ ",", "cr: \r", "new line: \n" },
                &.{ "a", "b", "c" },
                &.{ "hello", "world", " leading and trailing spaces are fine " },
            },
        },
        .{
            .path = "quotes_escape.csv",
            .expected_error = null,
            .expected_table = &.{
                &.{ "Header One", "Header Two" },
                &.{ "\"Value\" One", "\"Value\" Two" },
            },
        },
        .{
            .path = "empty_cells.csv",
            .expected_error = null,
            .expected_table = &.{
                &.{ "a", "b", "c" },
                &.{ "1", "", "" },
                &.{ "1", "Brooklyn, NY", "https://some.website.io/" },
                &.{ "2", "3", "4" },
            },
        },
        .{
            .path = "json.csv",
            .expected_error = null,
            .expected_table = &.{
                &.{ "key", "val" },
                &.{
                    "1",
                    \\{"type": "Point", "coordinates": [102.0, 0.5]}
                    ,
                },
            },
        },
        // Invalid Cases (Prefix bad_)
        .{
            .path = "bad_column_too_long.csv",
            .expected_error = .{
                .err = csvz.Iterator.Error.FieldTooLong,
                .row = 1,
                .col = 0,
            },
            .expected_table = &.{
                &.{ "a", "b" },
            },
            .buffer_size = 34, // enough for vectorization in x86 but smaller than column.
        },
        .{
            .path = "bad_column_too_long_quote.csv",
            .expected_error = .{
                .err = csvz.Iterator.Error.FieldTooLong,
                .row = 1,
                .col = 0,
            },
            .expected_table = &.{
                &.{ "a", "b" },
            },
            .buffer_size = 34, // enough for vectorization in x86 but smaller than column.
        },
        .{
            .path = "bad_unescaped_quotes.csv",
            .expected_error = .{
                .err = csvz.Iterator.Error.InvalidQuotes,
                .row = 1,
                .col = 1,
            },
            .expected_table = &.{
                &.{ "a", "b", "c" },
                &.{ "d", "", "" },
            },
        },
        .{
            .path = "bad_no_closing_quote_delim.csv",
            .expected_error = .{
                .err = csvz.Iterator.Error.InvalidQuotes,
                .row = 1,
                .col = 1,
            },
            .expected_table = &.{
                &.{ "a", "b", "c" },
                &.{ "d", "", "" },
            },
        },
        .{
            .path = "bad_quote_in_unquoted_region.csv",
            .expected_error = .{
                .err = csvz.Iterator.Error.InvalidQuotes,
                .row = 1,
                .col = 1,
            },
            .expected_table = &.{
                &.{ "a", "b", "c" },
                &.{ "d", "", "" },
            },
        },
    };

    for (test_cases) |tt| {
        errdefer std.debug.print("\ntt: path={s}\n", .{tt.path});

        const path = try std.mem.concat(std.testing.allocator, u8, &.{ "test/", tt.path });
        defer std.testing.allocator.free(path);

        const test_file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer test_file.close();

        const read_buffer: []u8 = try std.testing.allocator.alloc(u8, tt.buffer_size);
        defer std.testing.allocator.free(read_buffer);

        var file_reader = test_file.reader(read_buffer);

        var it = csvz.Iterator.init(&file_reader.interface);
        try tt.run(&it);
    }
}

test "emitter" {
    const TestCase = struct {
        name: []const u8,
        table: Table,
        expectation: []const u8,
    };

    const cases: []const TestCase = &.{
        .{
            .name = "simple",
            .table = &.{
                &.{ "header one", "header two" },
                &.{ "value one", "value two" },
            },
            .expectation =
            \\header one,header two
            \\value one,value two
            ,
        },
        .{
            .name = "mixed quotes",
            .table = &.{
                &.{ "header one", "header \"two\"" },
                &.{ "value, one", "value two" },
            },
            .expectation =
            \\header one,"header ""two"""
            \\"value, one",value two
            ,
        },
    };

    for (cases) |tt| {
        const ally = std.testing.allocator;
        var writer = std.Io.Writer.Allocating.init(ally);
        defer writer.deinit();

        var emitter = csvz.Emitter.init(&writer.writer);
        for (tt.table) |row| {
            for (row) |col| {
                try emitter.emit(col);
            }
            emitter.next_row();
        }

        if (!std.mem.eql(u8, writer.written(), tt.expectation)) {
            std.log.err("\nexpected:\n{s}\n\nreceived:\n{s}\n\n", .{ tt.expectation, writer.written() });
            return error.UnequalEmitterOutput;
        }
    }
}
