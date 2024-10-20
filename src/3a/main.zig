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

    try node.services.append(bcast.service());

    node.run(null, null) catch |err| {
        log.err("node died with err: {}", .{err});
        std.posix.exit(1);
    };
}

const Types = enum { read, broadcast, topology };

const broadcast = struct {
    type: []const u8,
    msg_id: usize,
    in_reply_to: ?usize = null,
    message: ?usize = null,
};

const read = struct {
    type: []const u8,
    msg_id: usize,
    in_reply_to: ?usize = null,
    messages: ?[]usize = null,
};

const MQ = std.TailQueue(std.json.Parsed(Message(std.json.Value)));

pub const Bcast = struct {
    node: *Node = undefined,
    allocator: std.mem.Allocator,

    status: State = .uninitialized,
    messages: std.ArrayList(usize) = undefined,
    message_set: std.EnumSet(Types) = std.EnumSet(Types).initFull(),

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    queue: MQ,

    pub fn init(allocator: std.mem.Allocator) Bcast {
        return Bcast{
            .allocator = allocator,
            .messages = std.ArrayList(usize).init(allocator),
            .status = .initialized,
            .queue = MQ{},
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Bcast) void {
        self.thread.?.join();
        self.running.store(false, .seq_cst);
        self.status = .stopped;
        self.messages.deinit();
        self.thread = null;
    }

    fn reply(self: *Bcast, msg: anytype) void {
        self.node.reply(msg) catch |err| {
            log.err("failed to send reply: {}", .{err});
        };
    }

    fn processMessages(self: *Bcast) void {
        while (self.running.load(.seq_cst)) {
            if (self.queue.popFirst()) |node| {
                self.handleMessage(node.data.value);
                node.data.deinit();
            } else std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    pub fn handleMessage(self: *Bcast, msg: Message(std.json.Value)) void {
        switch (std.meta.stringToEnum(Types, msg.body.object.get("type").?.string) orelse return) {
            .broadcast => {
                const bcast_msg = msg.fromValue(broadcast, self.allocator) catch |err| {
                    log.err("failed to destructure broadcast mesage: {}", .{err});
                    return;
                };
                defer bcast_msg.deinit();
                self.messages.append(bcast_msg.value.message.?) catch {
                    log.err("failed to append to message log", .{});
                    return;
                };
                self.reply(msg.into(broadcast, .{
                    .type = "broadcast_ok",
                    .msg_id = self.node.nextId(),
                    .in_reply_to = bcast_msg.value.msg_id,
                }));
            },
            .read => {
                const read_msg = msg.fromValue(read, self.allocator) catch |err| {
                    log.err("failed to destructure broadcast mesage: {}", .{err});
                    return;
                };
                defer read_msg.deinit();
                self.reply(msg.into(read, .{
                    .type = "read_ok",
                    .msg_id = self.node.nextId(),
                    .in_reply_to = read_msg.value.msg_id,
                    .messages = self.messages.items,
                }));
            },
            .topology => {
                const response = .{
                    .type = "topology_ok",
                    .msg_id = self.node.nextId(),
                    .in_reply_to = msg.body.object.get("msg_id").?.integer,
                };
                self.reply(msg.into(@TypeOf(response), response));
            },
        }
    }

    fn handle(ctx: *anyopaque, msg: std.json.Parsed(Message(std.json.Value))) void {
        const self = getSelf(ctx);
        _ = blk: {
            const node = self.allocator.create(MQ.Node) catch |err| break :blk err;
            node.* = MQ.Node{ .data = msg };
            self.queue.append(node);
        } catch |err| {
            log.err("failed to add message to queue: {}", .{err});
        };
    }

    pub fn service(self: *Bcast) Service {
        return .{
            .ptr = self,
            .vtable = &.{
                .start = start,
                .handle = handle,
                .state = state,
                .contains = contains,
                .stop = stop,
            },
        };
    }

    fn getSelf(ctx: *anyopaque) *Bcast {
        return Node.alignCastPtr(Bcast, ctx);
    }

    pub fn start(ctx: *anyopaque, n: *Node) void {
        const self = getSelf(ctx);
        if (self.thread != null) return;

        self.node = n;
        self.thread = std.Thread.spawn(.{}, processMessages, .{self}) catch |err| {
            log.err("failed to start message processing thread: {}", .{err});
            return;
        };
        self.running.store(true, .seq_cst);
        self.status = .active;
    }

    pub fn state(ctx: *anyopaque) State {
        return getSelf(ctx).status;
    }

    pub fn stop(ctx: *anyopaque) void {
        const self = getSelf(ctx);

        if (self.thread == null) return;
        self.deinit();
    }

    pub fn contains(ctx: *anyopaque, msg_type: []const u8) bool {
        return getSelf(ctx).message_set.contains(
            std.meta.stringToEnum(Types, msg_type) orelse return false,
        );
    }
};
