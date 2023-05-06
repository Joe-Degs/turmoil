const std = @import("std");
const Node = @import("Node");
const Message = Node.Message;

/// recieve message and echo it back into the ether
pub fn main() !void {
    var node = Node.init(std.heap.page_allocator);
    try node.registerMethod("echo", echoHandler);

    node.run() catch {
        node.deinit();
        std.os.exit(1);
    };
}

pub fn echoHandler(node: *Node, msg: *Message) error{InvalidRequest}!void {
    msg.set("type", .{ .String = "echo_ok" }) catch unreachable;
    const msg_id = msg.get("msg_id").?.Integer;

    msg.set(
        "in_reply_to",
        .{ .Integer = msg_id },
    ) catch unreachable;

    msg.set("msg_id", .{
        .Integer = @intCast(i64, node.msg_id()),
    }) catch unreachable;

    msg.dest = msg.src;
    msg.src = node.id;
    try node.send(msg.*);
}
