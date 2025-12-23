# csv-zero

Zero Allocation, SIMD-accelerated CSV iterator and emitter in Zig.

This Zig library strives to be a fast csv iterator and emitter. It provides a simple API and does not allocate
heap memory unless instructed by the user when a single column cannot fit entirely in the reader buffer.

The iterator works with any buffered `std.Io.Reader` instance.

```zig
const csvz = @import("csvzero");

fn print_csv_columns_count(file_path: []const u8) !void {
    var file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
    var buffer: [64_000]u8 = undefined;
    var reader = file.reader(&buffer);
    const file_reader = &reader.interface;
    var csvit = csvz.Iterator.init(file_reader);
    var sum: usize = 0;
    while (true) {
        const col = csvit.next() catch |err| switch (err) {
            csvz.Iterator.Error.EOF => break,
            else => |e| return e,
        };
        _ = col;
        // access col.data for raw data or col.unescaped() to get the unescaped version.
        // std.debug.print("col: {s}, last? {}\n", .{ col.data, col.last_column });
        sum += 1;
    }
}
```
