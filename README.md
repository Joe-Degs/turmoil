# Solving Distributed Systems Challenges with Zig
Participating in [Gossiple Glomers](https://fly.io/dist-sys) using the
Zig programming language as a way to learn the language and also learn about
distributed systems and [maelstrom](https://github.com/jepsen-io/maelstrom).
I envision writing all sorts of distributed system things with this thing.

## Installation and Use
Git clone this project to use it, `src/Node.zig` contains the implementation of
of the maelstrom protocol that helps to interface with the maelstrom network and
testing framework, use it to interface with the maelstorm network, contains too
many bugs to be useful but it kinda works.

To add a new challenge or a distributed thing that can be tested against maelstrom,
add a new directory in `src/` and then go and prefill the following struct with the appropriate values
in the `build.zig` script so you can build and run tests.
```zig
const challenges = [_]struct {
    name: []const u8, // name of the directory the challenge is in
    description: []const u8,
    workload: []const u8, // maelstrom workload to test against

    // extra arguments for maelstrom like --time-limit, --node-count, --rate etc
    args: []const []const u8, 
}{ ... };
```

Look at `src/echo` or `src/echo-service` to look at how to interact with maelstrom
network using `src/Node.zig` and how to write something that can participate
in the network.

## Building and running challenges
To build all the challenges/projects from `src/` that have been added to the build script:
```
zig build -Dall
```

To build a specific challenge/project from `src/`, say one named `echo`:
```
zig build -Dchallenge=echo
```

To build and run the maelstom test for a particular challenge/binary, say one named `echo`:
```
zig build -Dchallenge=echo run
```
