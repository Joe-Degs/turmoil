const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // add option to build all binaries in the project
    const build_all = b.option(bool, "all", "Build all challenges in project. Cannot run challenge if this option is set") orelse false;
    const challenge_name = b.option([]const u8, "challenge", "Build a specific challenge. Available challenges: " ++ comptime challengeNames()) orelse "";

    // Creates a step for unit testing.
    const main_tests = b.addTest(.{
        .root_source_file = b.path(b.pathJoin(&.{ "src", "main.zig" })),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&main_tests.step);

    const node_module = b.addModule("Node", .{
        .root_source_file = b.path(b.pathJoin(&.{ "src", "Node.zig" })),
    });
    const ziglangSet = b.dependency("ziglangSet", .{});

    const run_step = b.step("run", "Run maelstrom test for challenge");

    inline for (challenges) |challenge| {

        // build the challenge binary
        const cbin = b.addExecutable(.{
            .name = challenge.name,
            .root_source_file = b.path(b.pathJoin(&.{ "src", challenge.name, "main.zig" })),
            .target = target,
            .optimize = optimize,
        });
        cbin.root_module.addImport("Node", node_module);
        cbin.root_module.addImport("Set", ziglangSet.module("ziglangSet"));

        if (build_all) {
            b.installArtifact(cbin);
        } else if (std.mem.eql(u8, challenge_name, challenge.name)) {
            b.installArtifact(cbin);
            // add command to execute the maelstrom test for the challenge after build
            run_step.dependOn(b.getInstallStep());

            const exec_cmd = b.addSystemCommand(&[_][]const u8{
                b.pathJoin(&.{ "maelstrom", "maelstrom" }),
                "test",
                "-w",
                challenge.workload,
                "--bin",
                b.pathJoin(&.{ "zig-out", "bin", challenge.name }),
            } ++ challenge.args);
            run_step.dependOn(&exec_cmd.step);
        }
    }
}

fn challengeNames() []const u8 {
    var all: []const u8 = "";
    inline for (challenges) |c| all = all ++ c.name ++ ", ";
    return all;
}

// For every challenge, we add the challenge's source directory and the
// specific maelstrom commands for running the test for the challenge
const challenges = [_]struct {
    name: []const u8, // name of the directory the challenge is in
    description: []const u8,
    workload: []const u8, // maelstrom workload to test against
    args: []const []const u8, // extra arguments for maelstrom
}{
    .{
        .name = "1a",
        .description = "send the given stream of bytes back into the ether; fly.io/dist-sys",
        .workload = "echo",
        .args = &[_][]const u8{ "--node-count", "1", "--time-limit", "10" },
    },
    .{
        .name = "1a",
        .description = "send the given stream of bytes back into the ether but with a node service; fly.io/dist-sys",
        .workload = "echo",
        .args = &[_][]const u8{ "--node-count", "1", "--time-limit", "10" },
    },
    .{
        .name = "2a",
        .description = "globally-unique ID generator; fly.io/dist-sys",
        .workload = "unique-ids",
        .args = &[_][]const u8{ "--time-limit", "30", "--rate", "1000", "--node-count", "3", "--availability", "total", "--nemesis", "partition" },
    },
    .{
        .name = "2b",
        .description = "globally-unique ID generator; fly.io/dist-sys",
        .workload = "unique-ids",
        .args = &[_][]const u8{ "--time-limit", "60", "--rate", "100000", "--node-count", "10", "--availability", "total", "--nemesis", "partition" },
    },
    .{
        .name = "3a",
        .description = "gossip messages between all nodes in the system; fly.io/dist-sys",
        .workload = "broadcast",
        .args = &[_][]const u8{ "--node-count", "1", "--time-limit", "20", "--rate", "10" },
    },
    .{
        .name = "3b",
        .description = "multi-node node broadcast accross a cluster with no partitions; fly.io/dist-sys",
        .workload = "broadcast",
        .args = &[_][]const u8{ "--node-count", "5", "--time-limit", "20", "--rate", "10" },
    },
};
