const builtin = @import("builtin");

/// suggests a good vector length for u8 types, which is used for the Csv iterators.
/// For some of these CPUs, a value is chosen based on benchmarks, others based on the research on what is recommended
/// for that CPU. For instance with AVX-2, 256-bit is recommended but using 64 bytes (512 bits) outperforms.
pub fn suggestVectorLength() ?comptime_int {
    const cpu = builtin.cpu;
    if (cpu.arch.isX86()) {
        if (cpu.has(.x86, .avx512f) and !cpu.hasAny(.x86, &.{ .prefer_256_bit, .prefer_128_bit })) return 64;
        if (cpu.hasAny(.x86, &.{ .prefer_256_bit, .avx2 }) and !cpu.has(.x86, .prefer_128_bit)) return 64;
        if (cpu.has(.x86, .sse)) return 32;
        if (cpu.hasAny(.x86, &.{ .mmx, .@"3dnow" })) return 16;
    } else if (cpu.arch.isArm()) {
        if (cpu.has(.arm, .neon)) return 16;
    } else if (cpu.arch.isAARCH64()) {
        if (cpu.has(.aarch64, .sve)) return 64;
        if (cpu.has(.aarch64, .neon)) return 32;
    } else if (cpu.arch.isPowerPC()) {
        if (cpu.has(.powerpc, .altivec)) return 16;
    } else if (cpu.arch.isMIPS()) {
        if (cpu.has(.mips, .msa)) return 16;
        if (cpu.has(.mips, .mips3d)) return 32;
    } else if (cpu.arch.isRISCV()) {
        // In RISC-V Vector Registers are length agnostic so there's no good way to determine the best size.
        // The usual vector length in most RISC-V cpus is 256 bits, however it can get to multiple kB.
        if (cpu.has(.riscv, .v)) {
            inline for (.{
                .{ .zvl65536b, 8192 },
                .{ .zvl32768b, 4096 },
                .{ .zvl16384b, 2048 },
                .{ .zvl8192b, 1024 },
                .{ .zvl4096b, 512 },
                .{ .zvl2048b, 256 },
                .{ .zvl1024b, 128 },
                .{ .zvl512b, 64 },
                .{ .zvl256b, 32 },
                .{ .zvl128b, 16 },
                .{ .zvl64b, 8 },
                .{ .zvl32b, 4 },
            }) |mapping| {
                if (cpu.has(.riscv, mapping[0])) return mapping[1];
            }

            return 32;
        }
    } else if (cpu.arch.isSPARC()) {
        if (cpu.hasAny(.sparc, &.{ .vis, .vis2, .vis3 })) return 8;
    } else if (cpu.arch.isWasm()) {
        if (cpu.has(.wasm, .simd128)) return 16;
    }
    return null;
}
