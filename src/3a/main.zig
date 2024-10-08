/// Single node broadcast system
const std = @import("std");
const Node = @import("Node");
const Message = Node.Message;
const Service = Node.Service;
const State = Node.State;

const log = std.log.scoped(.Bcast);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = try Node.init(allocator);
    defer node.deinit();

    var bcast = Bcast.init(allocator);
    defer bcast.deinit();

    // i'd like to do something like
    // try node.register(enum { broadcast, read, topology}, bcast.service())
    // and then when a message comes out of the socket it has its message type
    // as an enum instead of a string so that we can switch on that.
    try node.registerService("broadcast read topology", bcast.service());

    node.run(null, null) catch |err| {
        log.err("node died with err: {}", .{err});
        std.posix.exit(1);
    };
}

pub const Bcast = struct {
    node: *Node = undefined,
    allocator: std.mem.Allocator,
    status: State = .uninitialized,
    messages: std.ArrayList(std.json.Value) = undefined,

    pub fn init(allocator: std.mem.Allocator) Bcast {
        return Bcast{
            .allocator = allocator,
            .messages = std.ArrayList(std.json.Value).init(allocator),
            .status = .initialized,
        };
    }

    pub fn deinit(self: *Bcast) void {
        self.messages.deinit();
    }

    fn getSelf(ctx: *anyopaque) *Bcast {
        return Node.alignCastPtr(Bcast, ctx);
    }

    pub fn start(ctx: *anyopaque, n: *Node) void {
        const self = getSelf(ctx);
        self.node = n;
        // self.status = .running;
    }

    pub fn state(ctx: *anyopaque) State {
        return getSelf(ctx).status;
    }

    fn handle_bcast(self: *Bcast, msg: *Message) !void {
        const message = msg.get("message").?.integer;
        try self.messages.append(.{ .integer = message });

        msg.set("type", .{ .string = "broadcast_ok" }) catch unreachable;
        _ = msg.remove("message");
    }

    pub fn handle_read(self: *Bcast, msg: *Message) void {
        msg.set("type", .{ .string = "read_ok" }) catch unreachable;
        msg.set(
            "messages",
            .{ .array = self.messages },
        ) catch unreachable;
    }

    pub fn handle_topology(self: *Bcast, msg: *Message) void {
        _ = self;
        _ = msg.get("topology");

        msg.set("type", .{ .string = "topology_ok" }) catch unreachable;
        _ = msg.remove("topology");
    }

    fn handle(ctx: *anyopaque, msg: *Message) void {
        const self = getSelf(ctx);
        const msg_type = msg.getType();

        const msg_types = enum { broadcast, read, topology };

        switch (std.meta.stringToEnum(msg_types, msg_type) orelse unreachable) {
            .broadcast => self.handle_bcast(msg) catch |err| {
                log.err("failed to read: {}", .{err});
            },
            .read => self.handle_read(msg),
            .topology => self.handle_topology(msg),
        }

        msg.dest = msg.src;
        msg.src = self.node.id;
        self.node.send(msg, null) catch |err| {
            log.err("could not send out message: {}", .{err});
            unreachable;
        };
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
