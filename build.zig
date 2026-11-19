const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("turbovc3", .{
        .root_source_file = b.path("src/native/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addCSourceFile(.{ .file = b.path("src/native/dnx_idct_kernel.c"), .flags = &.{"-std=c11"} });
    mod.link_libc = true;

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addCSourceFile(.{ .file = b.path("src/native/dnx_idct_kernel.c"), .flags = &.{"-std=c11"} });
    tests.root_module.link_libc = true;
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run turbovc3 Zig package tests");
    test_step.dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "decode_frame0",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/decode_frame0.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "turbovc3", .module = mod },
            },
        }),
    });
    b.installArtifact(example);
    const run_example = b.addRunArtifact(example);
    run_example.addPassthruArgs();
    const example_step = b.step("example", "Decode frame 0 of an MXF (pass path after --)");
    example_step.dependOn(&run_example.step);

    const bench = b.addExecutable(.{
        .name = "native_decode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/native_decode.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "turbovc3", .module = mod },
            },
        }),
    });
    bench.root_module.link_libc = true;
    const install_bench = b.addInstallArtifact(bench, .{});
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    run_bench.step.dependOn(&install_bench.step);
    const bench_step = b.step("bench", "Benchmark the native frame decoder (pass MXF paths after --)");
    bench_step.dependOn(&run_bench.step);
    const bench_install_step = b.step("bench-install", "Build and install the native frame decoder benchmark");
    bench_install_step.dependOn(&install_bench.step);
}
