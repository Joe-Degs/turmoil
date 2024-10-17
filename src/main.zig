const std = @import("std");
const testing = std.testing;

const Node = @import("Node.zig");

pub fn main() !void {}

test {
    testing.refAllDecls(Node);
}
