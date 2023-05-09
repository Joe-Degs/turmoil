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

    // For every challenge, we add the challenge's source directory and the
    // specific maelstrom commands for running the test for the challenge
    const challenges = [_]struct {
        name: []const u8,
        workload: []const u8,
        args: []const []const u8,
    }{
        .{
            .name = "echo",
            .workload = "echo",
            .args = &[_][]const u8{ "--node-count", "1", "--time-limit", "10" },
        },
        .{
            .name = "maelstrom-unique-ids",
            .workload = "unique-ids",
            .args = &[_][]const u8{ "--time-limit", "30", "--rate", "1000", "--node-count", "3", "--time-limit", "10", "--availability", "total", "--nemesis", "partition" },
        },
    };

    const node_module = b.addModule("Node", .{
        .source_file = .{ .path = "./src/Node.zig" },
    });

    inline for (challenges) |challenge| {
        // build the challenge binary
        const exe = b.addExecutable(.{
            .name = challenge.name,
            .root_source_file = .{
                .path = "src/" ++ challenge.name ++ "/main.zig",
            },
            .target = target,
            .optimize = optimize,
        });
        exe.addModule("Node", node_module);
        exe.install();

        // add independent build step for each challenge
        const build_challenge = b.step(
            challenge.name,
            "Build " ++ challenge.name ++ " challenge",
        );
        build_challenge.dependOn(exe.builder.getInstallStep());

        // add command to execute the maelstrom test for the challenge after build
        const exec_cmd = b.addSystemCommand(&[_][]const u8{
            "./maelstrom/maelstrom",
            "test",
            "-w",
            challenge.workload,
            "--bin",
            "zig-out/bin/" ++ challenge.name,
        } ++ challenge.args);
        exec_cmd.step.dependOn(build_challenge);

        const exec_step = b.step(
            "run_" ++ challenge.name,
            "Run the " ++ challenge.name ++ " challenge",
        );
        exec_step.dependOn(&exec_cmd.step);
    }
}
