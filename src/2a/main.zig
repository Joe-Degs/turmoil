const std = @import("std");
const Node = @import("Node");

const log = std.log.scoped(.id_generator);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var node = try Node.init(arena.allocator());
    defer node.deinit();

    node.registerMethod("generate", generateId) catch |err| {
        log.err("failed to register id generator method: {}", .{err});
    };

    node.run(null, null) catch |err| {
        log.err("node run failed with error: {}", .{err});
        std.posix.exit(1);
    };
}

var id: usize = 1;

pub fn next() usize {
    return @atomicRmw(usize, &id, .Add, 1, .monotonic);
}

pub fn generateId(node: *Node, msg: Node.Message(std.json.Value)) !void {
    const id_str = try std.fmt.allocPrint(
        node.allocator,
        "{s}-{d}",
        .{ node.id, next() },
    );
    defer node.allocator.free(id_str);

    const payload = .{
        .type = "generate_ok",
        .msg_id = node.nextId(),
        .in_reply_to = msg.body.object.get("msg_id").?.integer,
        .id = id_str,
    };

    node.reply(msg.into(@TypeOf(payload), payload)) catch |err| {
        log.err("failed to reply msg: {}", .{err});
    };
}
