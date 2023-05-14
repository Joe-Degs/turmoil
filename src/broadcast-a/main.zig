/// Single node broadcast system
const std = @import("std");
const Node = @import("Node");
const Message = Node.Message;
const Service = Node.Service;
const State = Node.State;

pub fn main() !void {
    var node = try Node.init(std.heap.page_allocator);
    defer node.deinit();

    var bcast = try Bcast.init(std.heap.page_allocator);
    try node.registerService("broadcast read topology", bcast.service());

    node.run(null, null) catch {
        std.os.exit(1);
    };
}

pub const Bcast = struct {
    node: *Node = undefined,
    status: State = .uninitialized,
    messages: std.ArrayList(std.json.Value) = undefined,

    pub fn init(allocator: std.mem.Allocator) !*Bcast {
        return &.{
            .messages = std.ArrayList(std.json.Value).init(allocator),
            .status = .initialized,
        };
    }

    fn getSelf(ctx: *anyopaque) *Bcast {
        return Node.alignCastPtr(Bcast, ctx);
    }

    fn start(ctx: *anyopaque, n: *Node) void {
        const self = getSelf(ctx);
        self.node = n;
    }

    fn state(ctx: *anyopaque) State {
        return getSelf(ctx).status;
    }

    pub fn handle_bcast(self: *Bcast, msg: *Message) !void {
        const message = msg.get("message").?;
        try self.messages.append(message);

        msg.set("type", .{ .String = "broadcast_ok" }) catch unreachable;
        _ = msg.remove("message");
    }

    pub fn handle_read(self: *Bcast, msg: *Message) void {
        msg.set("type", .{ .String = "read_ok" }) catch unreachable;
        msg.set(
            "messages",
            .{ .Array = self.messages },
        ) catch unreachable;
    }

    pub fn handle_topology(self: *Bcast, msg: *Message) void {
        _ = self;
        _ = msg.get("topology");

        msg.set("type", .{ .String = "topology_ok" }) catch unreachable;
        _ = msg.remove("topology");
        return;
    }

    fn handle(ctx: *anyopaque, msg: *Message) void {
        const self = getSelf(ctx);
        const msg_type = msg.getType();

        if (std.mem.eql(u8, msg_type, "broadcast")) {
            self.handle_bcast(msg) catch unreachable;
        } else if (std.mem.eql(u8, msg_type, "read")) {
            self.handle_read(msg);
        } else if (std.mem.eql(u8, msg_type, "topology")) {
            self.handle_topology(msg);
        }

        msg.dest = msg.src;
        msg.src = self.node.id;
        self.node.send(msg, null) catch unreachable;
    }

    pub fn service(self: *Bcast) Service {
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
