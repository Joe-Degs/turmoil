const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // add option to build all binaries in the project
    const build_all = b.option(bool, "all", "Build all challenges in project. Cannot run challenge if this option is set") orelse false;
    const challenge_name = b.option([]const u8, "challenge", "Build (and run) a specific challenge") orelse "";

    const main = b.addExecutable(.{
        .name = "turmoil",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main.install();

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
            .name = "echo-service",
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

    const run_step = b.step("run", "run built challenge");

    inline for (challenges) |challenge| {
        // add a build challenge step for building a specific challenge
        const build_challenge = b.step(
            challenge.name,
            challenge.name ++ " challenge",
        );

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

        // add independent build step for each challenge
        build_challenge.dependOn(exe.builder.getInstallStep());

        if (build_all) {
            exe.install();
        } else if (std.mem.eql(u8, challenge_name, challenge.name)) {
            exe.install();

            // add command to execute the maelstrom test for the challenge after build
            const exec_cmd = b.addSystemCommand(&[_][]const u8{
                "./maelstrom/maelstrom",
                "test",
                "-w",
                challenge.workload,
                "--bin",
                "zig-out/bin/" ++ challenge.name,
            } ++ challenge.args);
            run_step.dependOn(&exec_cmd.step);
            // exec_cmd.step.dependOn(build_challenge);
        }
    }
}
