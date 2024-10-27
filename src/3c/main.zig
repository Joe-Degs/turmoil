/// Multi node broadcast
const std = @import("std");
const Node = @import("Node");
const Set = @import("Set").Set;

const Message = Node.Message;
const Service = Node.Service;
const State = Node.State;

const log = std.log.scoped(.multi_node_broadcast);

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

const Types = enum { read, broadcast, topology, gossip, gossip_ok };

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

const gossip = struct {
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
    messages: Set(usize) = undefined,
    neighborhood: std.ArrayList([]const u8),
    seen: std.StringHashMap(Set(usize)),
    message_set: std.EnumSet(Types) = std.EnumSet(Types).initFull(),

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    queue: MQ,
    mutex: std.Thread.RwLock,

    pub fn init(allocator: std.mem.Allocator) Bcast {
        return Bcast{
            .allocator = allocator,
            .messages = Set(usize).init(allocator),
            .seen = std.StringHashMap(Set(usize)).init(allocator),
            .neighborhood = std.ArrayList([]const u8).init(allocator),
            .status = .initialized,
            .queue = MQ{},
            .running = std.atomic.Value(bool).init(false),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Bcast) void {
        self.thread.?.join();
        self.running.store(false, .seq_cst);
        self.status = .stopped;
        self.messages.deinit();

        // remove neighbor stuff
        var it = self.seen.iterator();
        while (it.next()) |el| {
            self.allocator.destroy(el.key_ptr.*);
            el.value_ptr.*.deinit();
        }
        self.seen.deinit();

        self.thread = null;
    }

    fn reply(self: *Bcast, msg: anytype) void {
        self.node.reply(msg) catch |err|
            log.err("failed to reply message: {}, error: {}", .{ msg, err });
    }

    const GOSSIP_INTERVAL = 1500 * std.time.ns_per_ms;
    const BACKOFF_TIME = 10 * std.time.ns_per_ms;

    fn processMessages(self: *Bcast) void {
        var timer = std.time.Timer.start() catch |err|
            return log.err("failed to start timer: {}", .{err});

        while (self.running.load(.seq_cst)) {
            if (self.queue.popFirst()) |node| {
                self.handleMessage(node.data.value);
                node.data.deinit();
                self.allocator.destroy(node);
            } else std.time.sleep(BACKOFF_TIME);

            if (timer.read() >= GOSSIP_INTERVAL) {
                self.startGossipSequence();
                timer.reset();
            }
        }
    }

    pub fn startGossipSequence(self: *Bcast) void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        if (self.neighborhood.items.len < 1 and self.messages.cardinality() < 1) return;
        const msg = collectIntoSlice(self.allocator, self.messages) catch |err|
            return log.err("failed to collect set into slice: {}", .{err});
        defer self.allocator.free(msg);

        for (self.neighborhood.items) |neighbor| {
            self.node.send(Message(gossip).init(self.node.id, neighbor, .{
                .type = "gossip",
                .msg_id = self.node.nextId(),
                .messages = msg,
            }), null) catch |err|
                log.err("failed to send gossip sequence to '{s}': {}", .{ neighbor, err });
        }
    }

    pub fn handleMessage(self: *Bcast, msg: Message(std.json.Value)) void {
        switch (std.meta.stringToEnum(Types, msg.body.object.get("type").?.string) orelse return) {
            .broadcast => {
                const bcast_msg: std.json.Parsed(broadcast) = msg.fromValue(broadcast, self.allocator) catch |err| {
                    log.err("failed to destructure broadcast mesage: {}", .{err});
                    return;
                };
                defer bcast_msg.deinit();
                _ = blk: {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    const insert = self.messages.add(bcast_msg.value.message.?) catch |err| break :blk err;
                    if (!insert) break :blk error.FailedToAddSetElem;
                } catch |err|
                    return log.err("failed to append to message log: {}", .{err});

                self.reply(msg.into(broadcast, .{
                    .type = "broadcast_ok",
                    .msg_id = self.node.nextId(),
                    .in_reply_to = bcast_msg.value.msg_id,
                }));
            },
            .read => {
                const read_msg = msg.fromValue(read, self.allocator) catch |err|
                    return log.err("failed to destructure broadcast mesage: {}", .{err});
                defer read_msg.deinit();

                self.mutex.lockShared();
                defer self.mutex.unlockShared();
                const elements = collectIntoSlice(self.allocator, self.messages) catch |err|
                    return log.err("failed to read broadcast messages from mem: {}", .{err});
                defer self.allocator.free(elements);

                self.reply(msg.into(read, .{
                    .type = "read_ok",
                    .msg_id = self.node.nextId(),
                    .in_reply_to = read_msg.value.msg_id,
                    .messages = elements,
                }));
            },
            .topology => {
                _ = blk: {
                    const topology = msg.body.object.get("topology").?.object;
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    if (topology.get(self.node.id)) |neighbors| {
                        for (neighbors.array.items) |neighbor| {
                            const string = self.allocator.dupeZ(u8, neighbor.string) catch |err| break :blk err;
                            self.neighborhood.append(string) catch |err| break :blk err;
                        }
                    }
                } catch |err|
                    return log.err("failed to get and update topology: {}", .{err});

                log.info("node {s} can talk to {s}", .{
                    self.node.id,
                    std.mem.join(self.allocator, ", ", self.neighborhood.items) catch unreachable,
                });

                const response = .{
                    .type = "topology_ok",
                    .msg_id = self.node.nextId(),
                    .in_reply_to = msg.body.object.get("msg_id").?.integer,
                };
                self.reply(msg.into(@TypeOf(response), response));
            },
            .gossip => {
                const gossip_msg = msg.fromValue(gossip, self.allocator) catch |err|
                    return log.err("failed to destructure gossip mesage: {}", .{err});
                defer gossip_msg.deinit();

                const difference = blk: {
                    const gossip_messages = gossip_msg.value.messages orelse break :blk null;
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    _ = self.messages.appendSlice(gossip_messages) catch |err|
                        return log.err("failed to append gossip message: {}", .{err});

                    // now we find the difference of the two sets
                    var gossip_set = Set(usize).init(self.allocator);
                    defer gossip_set.deinit();
                    _ = gossip_set.appendSlice(gossip_messages) catch |err|
                        return log.err("failed to append gossip message: {}", .{err});

                    const diff_set = self.messages.differenceOf(gossip_set) catch |err|
                        return log.err("failed to get gossip difference: {}", .{err});
                    const diff = collectIntoSlice(self.allocator, diff_set) catch return;
                    break :blk diff;
                };
                if (difference) |diff| {
                    defer self.allocator.free(diff);
                    const response = .{
                        .type = "gossip_ok",
                        .msg_id = self.node.nextId(),
                        .in_reply_to = msg.body.object.get("msg_id").?.integer,
                        .messages = diff,
                    };
                    self.reply(msg.into(@TypeOf(response), response));
                }
            },
            .gossip_ok => {
                const gossip_msg = msg.fromValue(gossip, self.allocator) catch |err|
                    return log.err("failed to destructure gossip_ok message: {}", .{err});
                defer gossip_msg.deinit();

                self.mutex.lock();
                defer self.mutex.unlock();
                if (gossip_msg.value.messages) |messages| {
                    _ = self.messages.appendSlice(messages) catch |err|
                        log.err("failed to handle gossip_ok message: {}", .{err});
                }
            },
        }
    }

    // collect set elements into a slice and return that slice, allocates memory that should
    // be freed by the caller
    pub fn collectIntoSlice(allocator: std.mem.Allocator, set: Set(usize)) ![]usize {
        var it = set.iterator();
        var elements = try allocator.alloc(usize, set.cardinality());
        var i: usize = 0;
        while (it.next()) |el| : (i += 1) elements[i] = el.*;
        return elements;
    }

    fn handle(ctx: *anyopaque, msg: std.json.Parsed(Message(std.json.Value))) void {
        const self = getSelf(ctx);
        _ = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
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
