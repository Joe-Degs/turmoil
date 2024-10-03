const std = @import("std");
const Node = @import("Node");

pub fn main() !void {
    var node = try Node.init(std.heap.page_allocator);
    defer node.deinit();

    try node.registerMethod("generate", generateId);

    node.run(null, null) catch {
        std.posix.exit(1);
    };
}

var id: usize = 1;

pub fn next() usize {
    return @atomicRmw(usize, &id, .Add, 1, .monotonic);
}

pub fn generateId(node: *Node, msg: *Node.Message) !void {
    msg.set("type", .{ .string = "generate_ok" }) catch unreachable;

    const id_str = try std.fmt.allocPrint(
        node.allocator,
        "{s}-{d}",
        .{ node.id, next() },
    );
    defer node.allocator.free(id_str);
    msg.set("id", .{ .string = id_str }) catch unreachable;

    msg.dest = msg.src;
    msg.src = node.id;
    try node.send(msg, null);
}
