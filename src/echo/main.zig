const std = @import("std");
const Node = @import("Node");
const Message = Node.Message;

/// recieve message and echo it back into the ether
pub fn main() !void {
    var node = try Node.init(std.heap.page_allocator);
    defer node.deinit();

    try node.registerMethod("echo", echoHandler);

    node.run(null, null) catch {
        std.os.exit(1);
    };
}

pub fn echoHandler(node: *Node, msg: *Message) !void {
    msg.set("type", .{ .String = "echo_ok" }) catch unreachable;
    msg.dest = msg.src;
    msg.src = node.id;
    try node.send(msg, null);
}
