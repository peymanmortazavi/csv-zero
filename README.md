# csv-zero

**csv-zero** is a CSV parsing library written in Zig that exposes a **low-level, zero-allocation and SIMD-accelerated field iterator**.

It intentionally does less than typical CSV libraries. There is no record abstraction, no automatic allocation, and no opinionated data model. Instead, csv-zero provides the minimal mechanics of CSV parsing so you can build exactly what you need—explicitly and predictably—on top.

This library is designed for systems engineers and performance-sensitive tooling where control and transparency matter more than convenience.

## Core Ideas

- **Field-by-field iteration**, not records
- **Zero allocations by default**
- **Explicit ownership and lifetimes**
- **Use SIMD to improve performance**
- **Strict RFC 4180 compliance**
- **Predictable performance** with SIMD where available

csv-zero exposes CSV parsing as a small, composable primitive rather than a high-level abstraction.

## What csv-zero Provides

- Incremental parsing from a `*std.Io.Reader`
- Iteration over **fields**, with row boundaries exposed explicitly
- Support for LF and CRLF line endings
- Quoted fields and escaped quotes per RFC 4180
- SIMD-accelerated scanning (configurable)

Each field is returned as a slice into an internal buffer. No memory is allocated unless you explicitly copy data.

## What csv-zero Does _Not_ Do

- Allocate memory for fields or records
- Provide a row or record iterator
- Automatically build structs, maps, or columnar data
- Tolerate malformed or ambiguous CSV

These omissions are deliberate. csv-zero avoids hidden costs and ambiguous behavior.

## Why a Field Iterator?

csv-zero exposes a **field iterator by design**.

This approach:

- Avoids allocating or tracking record state
- Allows fields to span the entire buffer when needed
- Avoids edge cases where a single large row exceeds buffer limits

If you want records, structs, or column-oriented storage, you build them explicitly on top. Helper utilities may be added in the future, but the core API will remain field-based.

## CSV Validity Rules

csv-zero follows RFC 4180 with a strict interpretation:

- Quoted fields may contain delimiters and newlines
- Escaped quotes must be represented as `""`
- **Unquoted fields containing `"` are invalid**
- Invalid quoting produces a parse error

Strict validation simplifies fast paths and avoids ambiguous states.

---

## Installation

Add the dependency:

```sh
zig fetch --save git+https://github.com/peymanmortazavi/csv-zero.git
```

Import it in `build.zig` (one possible approach):

```zig
const csvzero = b.dependency("csvzero", .{});
your_target.root_module.addImport("csvzero", csvzero.module("csvzero"));
```

Then use it:

```zig
const csvz = @import("csvzero");
```

---

## Quick Start

### Count rows and fields

```zig
var file = try std.fs.cwd().openFile("data.csv", .{});
defer file.close();

const buffer: [64 * 1024]u8 = undefined;
var reader = file.reader(&buffer);
var it = csvz.Iterator.init(&reader.interface);

var rows: usize = 0;
var fields: usize = 0;

while (true) {
    const field = it.next() catch |err| switch (err) {
        csvz.Iterator.Error.EOF => break,
        else => return err,
    };

    fields += 1;
    rows += @intFromBool(field.last_column);
}
```

### Print every field

```zig
const data = "a,b\nc,d";
var reader = std.Io.Reader.fixed(data);
var it = csvz.Iterator.init(&reader);

var row: usize = 0;
var col: usize = 0;

while (true) {
    var field = it.next() catch |err| switch (err) {
        error.EOF => break,
        else => return err,
    };

    std.debug.print(
        "field[{d}][{d}] = {s}\n",
        .{ row, col, field.unescaped() },
    );

    if (field.last_column) {
        row += 1;
        col = 0;
    } else col += 1;
}
```

---

## Field Lifetime and Ownership

Fields are slices into an internal buffer.

They are **only guaranteed to be valid until the next call to `next()`**—unless you use a fixed buffer.

If you need to retain data, copy it explicitly:

```zig
const owned = try allocator.dupe(u8, field.unescaped());
```

This tradeoff is fundamental to zero-allocation parsing.

## Fixed Buffers

Using a fixed reader keeps field slices valid indefinitely:

```zig
const data = "a,b\nc,d";
var reader = std.Io.Reader.fixed(data);
var it = csvz.Iterator.init(&reader);
```

Since the buffer never changes, fields remain valid across iterations.

## Escaping and Unescaping

`Field.data` contains raw field bytes before any unescaping.

Unescaping is **lazy** and optional:

```zig
// using field.unescaped()
// has side-effect! overwrites buffer data (if unescaping is needed)
// and sets needs_unescape to false.
const value = field.unescaped();

// custom unescaping approach
if (field.needs_unescape) {
    const value = try std.mem.replaceOwned(u8, allocator, field.data, "\"\"", "\"");
}
```

Calling `unescaped()` overwrites the field data in the buffer.
If you prefer not to mutate the buffer or to use your own approach, you can use `needs_unescape` to learn if any
unescaping is necessary at all and access the raw field bytes via `field.data`.

## Custom Delimiters (e.g. TSV)

You can define specialized iterators:

```zig
const TsvIterator = csvz.Csv(.{ .delimiter = '\t' });
```

## SIMD Configuration

SIMD is enabled by default when available. Vector length (in bytes) is
chosen conservatively per architecture but can be overridden:

```zig
const NoSimd = csvz.Csv(.{ .vector_length = null });
const WideSimd = csvz.Csv(.{ .vector_length = 128 });
```

You can use **csv-race** repo to benchmark different vector lengths for your CPU architecture and use the best number
for your needs. Though if you do see marginal benefits, I ask that you submit a PR so everyone can benefit!

---

## Benchmarks

The companion project **csv-race** benchmarks csv-zero alongside other high-quality CSV parsers using realistic datasets and metrics (time, memory, cache behavior, branch misses).

See: [https://github.com/peymanmortazavi/csv-race](https://github.com/peymanmortazavi/csv-race)

As of now, the results are quite impressive and this library comes on top but this can always change. I highly
recommend that you use this repository to benchmark some top choices against your own dataset. The repository is
designed to allow you to run your own benchmarks.

---

## C API

A C API interface is available, though it underperforms compared to the Zig implementation. This performance gap exists because the compiler lacks visibility into implementation details when crossing language boundaries, preventing optimizations that would otherwise be possible with native Zig code.
Despite this limitation, the C API still outperforms all libraries currently included in the `csv-race` benchmark repository. See [C API](C_API.md) for complete API documentation.

You can build the examples using:

```sh
zig build -Dbuild-examples=true
```

The output directory is `zig-out/bin`

---

## Limitations (By Design)

- Fields must fit within the reader buffer
- No record abstraction
- Strict validation

If these constraints don’t fit your use case, csv-zero may not be the right tool.
