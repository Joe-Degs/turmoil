/// Single node broadcast system
const std = @import("std");
const Node = @import("Node");
const Set = @import("Set").Set;

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

    try node.registerService("broadcast read topology", bcast.service());

    node.run(null, null) catch |err| {
        log.err("node died with err: {}", .{err});
        std.os.exit(1);
    };
}

pub const Bcast = struct {
    node: *Node = undefined,
    allocator: std.mem.Allocator,
    status: State = .uninitialized,

    messages: Set(usize) = undefined,
    neigborhood: std.ArrayList([]const u8) = undefined,

    const M = enum { broadcast, read, topology };

    pub fn init(allocator: std.mem.Allocator) Bcast {
        return Bcast{
            .allocator = allocator,
            .messages = std.ArrayList(std.json.Value).init(allocator),
            .neigborhood = std.ArrayList([]const u8).init(allocator),
            .status = .initialized,
        };
    }

    pub fn deinit(self: *Bcast) void {
        self.messages.deinit();
    }

    fn getSelf(ctx: *anyopaque) *Bcast {
        return Node.alignCastPtr(Bcast, ctx);
    }

    fn start(ctx: *anyopaque, n: *Node) void {
        const self = getSelf(ctx);
        self.node = n;
        self.status = .running;
    }

    fn state(ctx: *anyopaque) State {
        return getSelf(ctx).status;
    }

    pub fn read(self: *Bcast, msg: *Message) void {
        msg.set("type", .{ .string = "read_ok" }) catch unreachable;
        msg.set(
            "messages",
            .{ .array = self.messages },
        ) catch unreachable;
    }

    pub fn topology(self: *Bcast, msg: *Message) !void {
    }

    fn handle(ctx: *anyopaque, msg: *Message) void {
        const self = getSelf(ctx);

        switch (std.meta.stringToEnum(msg.getType(), M)) {
            .read => self.read(),
            .topology => self.topology() catch |err| { log.err("error while handling topology: {}", .{err}); },
        }
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
