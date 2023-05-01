const std = @import("std");
const testing = std.testing;

const Node = @import("Node.zig");

pub fn main() !void {
    var node: Node = .{};

    // read in through stdout
    var reader = node.reader();
    var buf: [100]u8 = undefined;
    _ = try reader.readAll(&buf);

    // write to stdout
    var writer = node.writer();
    try writer.writeAll(&buf);
    try writer.print("writing out of stdout for funzies!\n", .{});

    const number = i64;
    var the_number = @as(number, 30);
    try writer.print("{d}\n", .{the_number});

    try node.flush();
}

test {
    testing.refAllDecls(Node);
}
