const std = @import("std");
const Node = @import("Node");
const Message = Node.Message;

/// recieve message and echo it back into the ether
pub fn main() !void {
    var node = try Node.init(std.heap.page_allocator);
    defer node.deinit();

    try node.registerMethod("echo", echoHandler);

    node.run(null, null) catch {
        std.posix.exit(1);
    };
}

pub fn echoHandler(node: *Node, msg: Message(std.json.Value)) !void {
    const echo = .{
        .type = "echo_ok",
        .msg_id = node.nextId(),
        .in_reply_to = msg.body.object.get("msg_id").?.integer,
        .echo = msg.body.object.get("echo").?.string,
    };
    const response = msg.into(@TypeOf(echo), echo);
    try std.json.stringify(response, .{}, std.io.getStdErr().writer());
    try node.reply(response);
}
