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

const Types = enum { read, broadcast, topology, gossip };

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
    seen: std.StringHashMap(*Set(usize)),
    message_set: std.EnumSet(Types) = std.EnumSet(Types).initFull(),

    gossip_thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    mutex: std.Thread.RwLock,

    read_buf: std.ArrayList(usize),

    const GOSSIP_INTERVAL = 500 * std.time.ns_per_ms;

    pub fn init(allocator: std.mem.Allocator) Bcast {
        return Bcast{
            .allocator = allocator,
            .messages = Set(usize).init(allocator),
            .seen = std.StringHashMap(*Set(usize)).init(allocator),
            .neighborhood = std.ArrayList([]const u8).init(allocator),
            .read_buf = std.ArrayList(usize).init(allocator),
            .status = .initialized,
            .mutex = .{},
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Bcast) void {
        self.status = .stopped;

        self.running.store(false, .seq_cst);
        self.gossip_thread.?.join();

        self.messages.deinit();

        var it = self.seen.iterator();
        while (it.next()) |el| {
            self.allocator.free(el.key_ptr.*);
            el.value_ptr.*.*.deinit();
            self.allocator.destroy(el.value_ptr.*);
        }
        self.seen.deinit();
    }

    fn reply(self: *Bcast, msg: anytype) void {
        self.node.reply(msg) catch |err|
            log.err("failed to reply message: {}, error: {}", .{ msg, err });
    }

    pub fn runGossipSequence(self: *Bcast) void {
        var timer = std.time.Timer.start() catch |err|
            return log.err("failed to start gossip interval timer: {}", .{err});

        while (self.running.load(.seq_cst)) {
            if (timer.read() >= GOSSIP_INTERVAL) {
                self.doGossip();
                timer.reset();
            }
        }
    }

    pub fn doGossip(self: *Bcast) void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        if (self.neighborhood.items.len < 1 or self.messages.cardinality() < 1) return;

        for (self.neighborhood.items) |neighbor| {
            const msg = blk: {
                if (self.seen.get(neighbor)) |neighbor_set| {
                    const diff_set = self.messages.differenceOf(neighbor_set.*) catch |err|
                        break :blk err;
                    const diff = collectIntoList(&self.read_buf, diff_set) catch |err|
                        break :blk err;
                    break :blk diff;
                }
                break :blk collectIntoList(&self.read_buf, self.messages) catch |err| {
                    log.err("failed to collect set into slice for gossip: neighbor {s}, error {}", .{ neighbor, err });
                    continue;
                };
            } catch |err| {
                log.err("failed to get gossip message for neighbor: '{s}', error: {}", .{ neighbor, err });
                continue;
            };
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

                self.mutex.lock();
                defer self.mutex.unlock();
                const elements = collectIntoList(&self.read_buf, self.messages) catch |err|
                    return log.err("failed to read broadcast messages from mem: {}", .{err});

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

                {
                    const gossip_messages = gossip_msg.value.messages orelse return;
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    _ = self.messages.appendSlice(gossip_messages) catch |err|
                        return log.err("failed to append gossip message: {}", .{err});

                    // now we find the difference of the two sets
                    const gossip_set = clk: {
                        if (self.seen.get(msg.src)) |set| {
                            break :clk set;
                        } else {
                            const neighbor = self.allocator.dupeZ(u8, msg.src) catch |err|
                                return log.err("failed to dupe neighbor string: {}", .{err});

                            const neighbor_set = self.allocator.create(Set(usize)) catch |err|
                                return log.err("failed to create set of neighbor messages: {}", .{err});
                            neighbor_set.* = Set(usize).init(self.allocator);

                            self.seen.put(neighbor, neighbor_set) catch |err|
                                return log.err("failed to create neighbor history set: {}", .{err});
                            break :clk neighbor_set;
                        }
                    };

                    _ = gossip_set.appendSlice(gossip_messages) catch |err|
                        return log.err("failed to append gossip message: {}", .{err});
                }
            },
        }
    }

    pub fn collectIntoList(list: *std.ArrayList(usize), set: Set(usize)) ![]usize {
        const elems = set.cardinality();
        list.clearRetainingCapacity();
        try list.ensureTotalCapacity(elems);

        var it = set.iterator();
        while (it.next()) |el| try list.append(el.*);
        return list.items[0..elems];
    }

    fn handle(ctx: *anyopaque, msg: std.json.Parsed(Message(std.json.Value))) void {
        const self = getSelf(ctx);
        defer msg.deinit();
        self.handleMessage(msg.value);

        // if (self.node.next_id % 20 == 0) {
        //     var it = self.seen.iterator();
        //     while (it.next()) |entry| {
        //         const elems = collectIntoSlice(self.allocator, entry.value_ptr.*.*) catch continue;
        //         log.info("node {s} knows node {s} has seen {any}", .{
        //             self.node.id,
        //             entry.key_ptr.*,
        //             elems,
        //         });
        //         self.allocator.free(elems);
        //     }
        // }
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
        self.node = n;
        self.status = .active;

        self.gossip_thread = std.Thread.spawn(.{}, runGossipSequence, .{self}) catch |err|
            return log.err("failed to start gossip thread for node '{s}': {}", .{ n.id, err });
        self.running.store(true, .seq_cst);
    }

    pub fn state(ctx: *anyopaque) State {
        return getSelf(ctx).status;
    }

    pub fn stop(ctx: *anyopaque) void {
        const self = getSelf(ctx);
        self.deinit();
    }

    pub fn contains(ctx: *anyopaque, msg_type: []const u8) bool {
        return getSelf(ctx).message_set.contains(
            std.meta.stringToEnum(Types, msg_type) orelse return false,
        );
    }
};
