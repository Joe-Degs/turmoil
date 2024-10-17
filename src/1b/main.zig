const std = @import("std");
const Node = @import("Node");
const Message = Node.Message;
const Service = Node.Service;
const State = Node.State;

const log = std.log.scoped(.echo);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var node = try Node.init(arena.allocator());
    defer node.deinit();

    var echo: Echo = .{};
    try node.services.append(echo.service());

    node.run(null, null) catch {
        std.posix.exit(1);
    };
}

pub const Echo = struct {
    node: *Node = undefined,
    status: State = .uninitialized,
    msg_set: Node.MessageSet = Node.MessageSet.init(.{ .echo = true }),

    fn getSelf(ctx: *anyopaque) *Echo {
        return Node.alignCastPtr(Echo, ctx);
    }

    fn start(ctx: *anyopaque, n: *Node) void {
        const self = getSelf(ctx);
        self.node = n;
        self.status = .active;
    }

    fn state(ctx: *anyopaque) State {
        return getSelf(ctx).status;
    }

    fn stop(ctx: *anyopaque) void {
        _ = ctx;
    }

    fn set(ctx: *anyopaque) Node.MessageSet {
        return getSelf(ctx).msg_set;
    }

    const EchoMsg = struct {
        type: []const u8,
        msg_id: usize,
        in_reply_to: ?usize = null,
        echo: []const u8,
    };

    fn echo(self: Echo, msg: Message(std.json.Value)) !void {
        const echo_res = msg.into(EchoMsg, .{
            .type = "echo_ok",
            .msg_id = self.node.nextId(),
            .in_reply_to = @intCast(msg.body.object.get("msg_id").?.integer),
            .echo = msg.body.object.get("echo").?.string,
        });
        try self.node.reply(echo_res);
    }

    fn handle(ctx: *anyopaque, msg: Message(std.json.Value)) void {
        getSelf(ctx).echo(msg) catch |err| {
            log.err("failed while handling request: {}", .{err});
        };
    }

    fn service(self: *Echo) Service {
        return .{
            .ptr = self,
            .vtable = &.{
                .start = start,
                .handle = handle,
                .state = state,
                .stop = stop,
                .set = set,
            },
        };
    }
};
