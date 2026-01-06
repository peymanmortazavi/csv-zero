const std = @import("std");
const csvz = @import("csvzero");

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    const filename = args.next() orelse {
        std.log.err("missing filename", .{});
        std.process.exit(1);
    };

    const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
    var buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(&buffer);
    var it = csvz.Iterator.init(&file_reader.interface);

    var row: usize = 0;
    var col: usize = 0;
    while (true) {
        var field = it.next() catch |err| switch (err) {
            error.EOF => break,
            else => {
                std.log.err("err {s} at row={d}, col={d}", .{ @errorName(err), row, col });
                std.process.exit(1);
            },
        };

        std.debug.print("field[{d}][{d}] = |{s}|\n", .{ row, col, field.unescaped() });
        if (field.last_column) {
            row += 1;
            col = 0;
        } else col += 1;
    }
}
