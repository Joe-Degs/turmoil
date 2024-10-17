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
        std.posix.exit(1);
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
            .messages = Set(usize).init(allocator),
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
        // self.status = .running;
    }

    fn state(ctx: *anyopaque) State {
        return getSelf(ctx).status;
    }

    const ReadOk = struct { type: []const u8 = "read_ok", messages: std.ArrayList(usize) };

    pub fn read(self: *Bcast, msg: *Message) !void {
        var message_list = std.ArrayList(usize).init(self.allocator);
        defer message_list.deinit();

        if (!self.messages.isEmpty()) {
            var message_it = self.messages.iterator();
            while (message_it.next()) |message| try message_list.append(message.*);
        }

        // msg.set("type", .{ .string = "read_ok" }) catch unreachable;
        // msg.set(
        //     "messages",
        //     .{ .array = message_list },
        // ) catch unreachable;

        const response = try Message.from(self.allocator, self.node.id, msg.src, &ReadOk{
            .messages = message_list,
        });

        try self.node.reply(response);
    }

    pub fn topology(self: *Bcast, msg: *Message) !void {
        const neigborhood = try std.json.parseFromValue(
            []const []const u8,
            self.allocator,
            msg.get("topology").?.object.get(self.node.id).?,
            .{},
        );
        defer self.deinit();
        self.neigborhood.clearRetainingCapacity();
        try self.neigborhood.appendSlice(neigborhood.value);

        // send a topology ok
        msg.set("type", .{ .string = "topology_ok" }) catch unreachable;
        _ = msg.remove("topology");
        try self.node.reply(msg);
    }

    pub fn broadcast(self: *Bcast, msg: *Message) !void {
        const message = msg.get("message").?.integer;
        if (try self.messages.add(@intCast(message))) {
            msg.set("type", .{ .string = "broadcast_ok" }) catch unreachable;
            _ = msg.remove("message");
            try self.node.reply(msg);
        }
    }

    fn handle(ctx: *anyopaque, msg: *Message) void {
        const self = getSelf(ctx);

        switch (std.meta.stringToEnum(M, msg.getType()).?) {
            .read => self.read(msg) catch |err| {
                log.err("failed to read: {}", .{err});
            },
            .topology => self.topology(msg) catch |err| {
                log.err("error while handling topology: {}", .{err});
            },
            .broadcast => self.broadcast(msg) catch |err| {
                log.err("error while handling broadcast: {}", .{err});
            },
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
