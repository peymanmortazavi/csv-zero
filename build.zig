const std = @import("std");

pub fn build(b: *std.Build) !void {
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

    const build_examples = b.option(
        bool,
        "build-examples",
        "Build all examples (every .c file gets compiled as a separate binary target)",
    );
    if (build_examples != null and build_examples.?) {
        const example = b.addExecutable(.{
            .name = "iterate_fields",
            .root_module = b.addModule("examples", .{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("examples/iterate_fields.zig"),
            }),
        });
        example.root_module.addImport("csvzero", mod);
        b.installArtifact(example);

        try buildCExamples(b, target, lib);
    }
}

fn buildCExamples(b: *std.Build, target: std.Build.ResolvedTarget, lib: *std.Build.Step.Compile) !void {
    const examples_dir = try std.fs.cwd().openDir("examples", .{ .iterate = true });
    var it = examples_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".c"))
            continue;

        const name = try std.fmt.allocPrint(
            b.allocator,
            "c_{s}",
            .{entry.name[0 .. entry.name.len - 2]}, // drop .c
        );
        defer b.allocator.free(name);

        const c_simple_example = b.addExecutable(.{
            .name = name,
            .root_module = b.addModule(
                name,
                .{ .target = target, .link_libc = true, .optimize = .ReleaseFast },
            ),
        });
        const path = try std.fmt.allocPrint(
            b.allocator,
            "examples/{s}",
            .{entry.name},
        );
        defer b.allocator.free(path);
        c_simple_example.addCSourceFile(.{
            .file = b.path(path),
        });
        c_simple_example.linkLibrary(lib);
        b.installArtifact(c_simple_example);
    }
}
