const std = @import("std");
const Node = @import("Node");
const Message = Node.Message;

/// recieve message and echo it back into the ether
pub fn main() !void {
    var node = Node.init(std.heap.page_allocator);
    errdefer node.deinit();

    try node.registerMethod("echo", echoHandler);

    node.run() catch {
        std.os.exit(1);
    };
}

pub fn echoHandler(node: *Node, msg: Message) error{InvalidRequest}!void {
    _ = node;
    _ = msg;
}
