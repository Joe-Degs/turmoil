const std = @import("std");
const Node = @import("Node");

const Message = Node.Message;
const Service = Node.Service;
const State = Node.State;

const log = std.log.scoped(.id_generator);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var node = try Node.init(arena.allocator());
    defer node.deinit();

    var generator = UniqueIdGenerator.init(arena.allocator());
    try node.services.append(generator.service());

    node.run(null, null) catch |err| {
        log.err("node {s}, failed while running with error: {}", .{ node.id, err });
        std.posix.exit(1);
    };
}

pub const UniqueIdGenerator = struct {
    node: *Node = undefined,
    status: State = .uninitialized,

    allocator: std.mem.Allocator,
    node_id: ?u32,
    counter: std.atomic.Value(u32),

    const msg_set = Node.MessageSet.init(.{ .generate = true });

    const Generate = struct {
        type: []const u8,
        msg_id: usize,
        in_reply_to: ?usize = null,
        id: ?u128 = null,
    };

    fn init(allocator: std.mem.Allocator) UniqueIdGenerator {
        return UniqueIdGenerator{
            .allocator = allocator,
            .node_id = null,
            .counter = std.atomic.Value(u32).init(0),
        };
    }

    fn getSelf(ctx: *anyopaque) *UniqueIdGenerator {
        return Node.alignCastPtr(UniqueIdGenerator, ctx);
    }

    fn start(ctx: *anyopaque, n: *Node) void {
        const self = getSelf(ctx);
        self.node = n;
        self.status = .active;
    }

    fn state(ctx: *anyopaque) State {
        return getSelf(ctx).status;
    }

    fn set(_: *anyopaque) Node.MessageSet {
        return msg_set;
    }

    fn stop(_: *anyopaque) void {}

    fn getNodeIdNumber(self: *UniqueIdGenerator) !u32 {
        if (self.node_id == null and self.node.status != .uninitialized) {
            self.node_id = try std.fmt.parseUnsigned(u32, self.node.id[1..], 10);
        }
        return self.node_id orelse error.NodeNotInitialized;
    }

    fn generatId(self: *UniqueIdGenerator, msg: Message(Generate)) !void {
        var current_time = std.time.milliTimestamp();
        var counter_value = self.counter.fetchAdd(1, .monotonic);

        if (counter_value == std.math.maxInt(u32)) {
            counter_value = self.counter.swap(0, .monotonic);
            while (std.time.milliTimestamp() == current_time) {
                std.time.sleep(100 * std.time.ns_per_s);
            }
            current_time = std.time.milliTimestamp();
        }

        try self.node.reply(msg.into(Generate, .{
            .type = "generate_ok",
            .msg_id = self.node.nextId(),
            .in_reply_to = msg.body.msg_id,
            .id = (@as(u128, @intCast(current_time)) << 64) | (@as(u128, try self.getNodeIdNumber()) << 32) | counter_value,
        }));
    }

    fn handle(ctx: *anyopaque, msg: Message(std.json.Value)) void {
        const self = getSelf(ctx);
        self.generatId(msg.fromValue(Generate, self.allocator) catch unreachable) catch |err| {
            log.err("failed while generating id: {}", .{err});
        };
    }

    fn service(self: *UniqueIdGenerator) Service {
        return .{
            .ptr = self,
            .vtable = &.{
                .start = start,
                .handle = handle,
                .state = state,
                .set = set,
                .stop = stop,
            },
        };
    }
};
