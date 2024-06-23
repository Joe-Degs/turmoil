# Solving Distributed Systems Challenges with Zig
Participating in [Gossiple Glomers](https://fly.io/dist-sys) using the
Zig programming language as a way to learn the language and also learn about
distributed systems and [maelstrom](https://github.com/jepsen-io/maelstrom).
I envision writing all sorts of distributed system things with this thing.

## Installation and Use
clone this project. `src/Node.zig` contains the implementation of
of the maelstrom protocol that helps to interface with the maelstrom network and
testing framework, use it to interface with the maelstorm network, contains too
many bugs to be useful but it kinda works.

### maelstrom setup
Download the latest maelstrom package from the github releases into the root of the cloned
repository. You need the java runtime environment to run maelstrom.

### adding new chanllenges
To add a new challenge (or a distributed system that can be tested in maelstrom),
add a new directory in `src/`, add the new system's name, description and system specific
commandline args to the `./build.zig`.

An example of this is;
```zig
const challenges = [_]struct {
    name: []const u8, // name of the directory the challenge is in
    description: []const u8,
    workload: []const u8, // maelstrom workload to test against

    // extra arguments for maelstrom like --time-limit, --node-count, --rate etc
    args: []const []const u8, 
}{
    .{
        .name = "echo",
        .description = "echo challenge",
        .workload = "echo",
        .args = &[_][]const u8{ "--node-count", "1", "--time-limit", "10" },
    },
...
};
```
Look at `src/echo` or `src/echo-service` to look at how to interact with maelstrom
network using `src/Node.zig` and how to write something that can participate
in the network.

### building and running the challenges
To build all the challenges/projects from `src/` that have been added to the build script:
```
zig build -Dall
```

To build a specific challenge/project from `src/`, say one named `echo`:
```
zig build -Dchallenge=echo
```

To build and run the maelstom test for a particular challenge, say one named `echo`:
```
zig build -Dchallenge=echo run
```
