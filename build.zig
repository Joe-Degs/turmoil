const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const main = b.addExecutable(.{
        .name = "turmoil",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    main.install();

    const run_cmd = main.run();

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&main_tests.step);

    // add each challenge directory as a buildable artifact
    const challenges = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "echo",
        },
    };

    inline for (challenges) |challenge| {
        const exe = b.addExecutable(.{
            .name = challenge.name,
            .root_source_file = .{ .path = "src/" ++ challenge.name ++ "/main.zig" },
            .target = target,
            .optimize = optimize,
        });

        exe.install();

        const exec_cmd = exe.run();

        exec_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const exec_step = b.step("run", "Run the app");
        exec_step.dependOn(&run_cmd.step);
    }
}
