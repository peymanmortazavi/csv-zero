const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add option to choose between shared and static library
    const shared = b.option(bool, "shared", "Build shared library instead of static (default: false)") orelse false;

    const lib = b.addLibrary(.{
        .name = "csvzero",
        .linkage = if (shared) .dynamic else .static,
        .root_module = b.addModule("csvzero_c_api", .{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);

    // Install the header file
    b.installFile("include/csvzero.h", "include/csvzero.h");

    const mod = b.addModule("csvzero", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "csvzero", .module = mod },
            },
        }),
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
