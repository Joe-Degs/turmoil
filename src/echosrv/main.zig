const std = @import("std");
const Node = @import("Node");
const Message = Node.Message;
const Service = Node.Service;
const State = Node.State;

pub fn main() !void {
    var node = try Node.init(std.heap.page_allocator);
    defer node.deinit();

    var echo: Echo = .{};
    try node.registerService("echo|echo_ok", echo.service());

    node.run(null, null) catch {
        std.os.exit(1);
    };
}

pub const Echo = struct {
    node: *Node = undefined,
    status: State = .uninitialized,

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

    fn handle(ctx: *anyopaque, msg: *Message) void {
        const self = getSelf(ctx);
        msg.set("type", .{ .string = "echo_ok" }) catch unreachable;
        msg.dest = msg.src;
        msg.src = self.node.id;
        self.node.send(msg, null) catch unreachable;
    }

    fn service(self: *Echo) Service {
        return .{
            .ptr = self,
            .vtable = &.{
                .start = start,
                .handle = handle,
                .state = state,
            },
        };
    }
};
