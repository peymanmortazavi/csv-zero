const std = @import("std");
const csvz = @import("csvzero");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(std.heap.smp_allocator);
    defer args.deinit();

    _ = args.skip();
    const filename = args.next() orelse {
        std.log.err("missing filename", .{});
        std.process.exit(1);
    };

    const file = try std.Io.Dir.cwd().openFile(init.io, filename, .{ .mode = .read_only });
    var buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(init.io, &buffer);
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
