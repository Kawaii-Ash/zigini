const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ini = b.dependency("ini", .{});

    const zigini = b.addModule("zigini", .{
        .root_source_file = .{ .path = "src/main.zig" },
    });
    zigini.addImport("ini", ini.module("ini"));

    const example = b.addExecutable(.{
        .name = "example",
        .root_source_file = .{ .path = "example/example.zig" },
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("zigini", zigini);

    const example_exe = b.addRunArtifact(example);

    const example_step = b.step("example", "Run example");
    example_step.dependOn(&example_exe.step);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("ini", ini.module("ini"));

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}
