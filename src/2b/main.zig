const std = @import("std");
const Node = @import("Node");

const Message = Node.Message;
const Service = Node.Service;
const State = Node.State;

const log = std.log.scoped(.UniqueIDGenerator);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var node = try Node.init(arena.allocator());
    defer node.deinit();

    var generator = UniqueIdGenerator.init(arena.allocator());
    try node.registerService("generate", generator.service());

    node.run(null, null) catch {
        std.posix.exit(1);
    };
}

pub const UniqueIdGenerator = struct {
    node: *Node = undefined,
    status: State = .uninitialized,

    allocator: std.mem.Allocator,
    node_id: ?u32,
    counter: std.atomic.Value(u32),

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

    fn getNodeIdNumber(self: *UniqueIdGenerator) !u32 {
        if (self.node_id == null and self.node.status != .uninitialized) {
            log.info("getting node id for {s}", .{self.node.id});
            self.node_id = try std.fmt.parseUnsigned(u32, self.node.id[1..], 10);
        }
        return self.node_id orelse error.NodeNotInitialized;
    }

    fn generatId(self: *UniqueIdGenerator) ![]u8 {
        var current_time = std.time.milliTimestamp();
        var counter_value = self.counter.fetchAdd(1, .monotonic);

        if (counter_value == std.math.maxInt(u32)) {
            counter_value = self.counter.swap(0, .monotonic);
            while (std.time.milliTimestamp() == current_time) {
                std.time.sleep(100 * std.time.ns_per_s);
            }
            current_time = std.time.milliTimestamp();
        }
        return std.fmt.allocPrint(self.allocator, "n{d}-{x}-{d}", .{
            try self.getNodeIdNumber(),
            current_time,
            counter_value,
        });
    }

    fn handle(ctx: *anyopaque, msg: *Message) void {
        const self = getSelf(ctx);
        msg.set("type", .{ .string = "generate_ok" }) catch unreachable;
        const unique_id = self.generatId() catch |err| {
            log.err("failed to generate unique id: {}", .{err});
            return;
        };
        defer self.allocator.free(unique_id);
        msg.set("id", .{ .string = unique_id }) catch unreachable;
        msg.dest = msg.src;
        msg.src = self.node.id;
        self.node.send(msg, null) catch unreachable;
    }

    fn service(self: *UniqueIdGenerator) Service {
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
