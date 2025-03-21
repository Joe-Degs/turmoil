//! In maelstrom, Nodes, recieve messages from STDIN and send out responses through
//! the STDOUT. This file provides code to bootstrap a node that can be built upon
//! to do some work in the maelstrom network. It also provides the initial message
//! types that are used to prepare a node for participating in the network.
const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;

const log = std.log.scoped(.maelstrom_agent);

const Node = @This();

const stringify_options = .{ .emit_null_optional_fields = false };
const parse_options = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

pub const State = enum {
    /// node has not yet recieved an `init` request
    uninitialized,

    /// node has recieved an `init` request and has been initialized
    initialized,

    /// node/service is active and accepting requests
    active,

    /// service has stopped, can recieve requests but won't process them
    stopped,

    /// server has shutdown and is not handling any requests.
    shutdown,
};

/// standard output and input
const out = io.getStdOut().writer();
const in = io.getStdIn().reader();

/// Methods handle messages
const Method = *const fn (*Node, Message(std.json.Value)) anyerror!void;

allocator: Allocator = undefined,
arena: std.heap.ArenaAllocator = undefined,

/// unique string identifer used to route messages to and from the node
id: []u8 = &[_]u8{},

// temp buffer for storing bytes recieved from the network
stream_buf: std.ArrayList(u8),

/// msg_id of the next message that gets sent out from the node
next_id: usize = 1,

/// ids of maelstrom client/nodes in the network, they send messages to nodes and expect
/// responses back just like you. they are a node's peers in the network.
node_ids: std.ArrayList([]const u8) = undefined,

/// handlers are standalone functions that can process a message and send a response
/// they are always run synchronously
handlers: std.StringHashMap(Method) = undefined,

/// services are handlers but keep their own state and can run concurrently
/// with other node processes (though they are not doing that now).
/// It is also an interface with `handle`, `state`, `start` functions.
services: std.ArrayList(Service) = undefined,

/// the current state of a node
status: State = .uninitialized,

/// STDOUT and STDIN streams for sending and receiving message in the maelstrom network.
stdin: io.BufferedReader(4096, @TypeOf(in)) = io.bufferedReader(in),
stdout: io.BufferedWriter(4096, @TypeOf(out)) = io.bufferedWriter(out),

/// make a new node that is fit to participate in the network. An allocator is
/// needed to store things that the node relies on to do relevant work.
pub fn init(allocator: Allocator) !*Node {
    const node = try allocator.create(Node);
    node.* = Node{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .node_ids = std.ArrayList([]const u8).init(allocator),
        .stream_buf = try std.ArrayList(u8).initCapacity(allocator, 1024),

        // TODO(joe): consider not initialzing the hash maps until there is
        // something to register
        .handlers = std.StringHashMap(Method).init(allocator),
        .services = std.ArrayList(Service).init(allocator),
    };
    return node;
}

pub fn deinit(node: *Node) void {
    for (node.services.items) |service| service.stop();
    node.services.deinit();
    node.handlers.deinit();

    node.node_ids.deinit();
    node.stream_buf.deinit();
    if (node.id.len > 0) node.allocator.free(node.id);
    node.arena.deinit();
    node.allocator.destroy(node);
}

/// get the next msg_id from the node, can be called concurrently.
pub fn nextId(node: *Node) usize {
    return @atomicRmw(usize, &node.next_id, .Add, 1, .monotonic);
}

/// register a method to handle a specific type of message
pub fn registerMethod(node: *Node, typ: []const u8, method: Method) !void {
    return node.handlers.put(typ, method);
}

/// get stdout as a buffered write stream
pub fn writer(node: *Node) @TypeOf(node.stdout.writer()) {
    return node.stdout.writer();
}

/// get stdin as a buffered read stream
pub fn reader(node: *Node) @TypeOf(node.stdin.reader()) {
    return node.stdin.reader();
}

/// write everything in the buffer out to the the underlying stream.
pub fn flush(node: *Node) !void {
    try node.stdout.flush();
}

const Init = struct {
    type: []const u8 = "init",
    msg_id: usize,
    node_id: []const u8,
    node_ids: []const []const u8,
};

const InitOk = struct {
    type: []const u8 = "init_ok",
    in_reply_to: usize = 0,
    msg_id: usize = 0,
};

fn initializeNode(node: *Node, allocator: std.mem.Allocator, alt_reader: anytype, alt_writer: anytype) !void {
    if (node.status == .initialized) return;
    const init_payload = try node.readBytes(alt_reader) orelse return;
    var init_msg = try Message(Init).decode(allocator, init_payload);
    defer init_msg.deinit();

    var msg = init_msg.value;
    node.id = try node.allocator.alloc(u8, msg.body.node_id.len);
    @memcpy(node.id, msg.body.node_id);
    for (msg.body.node_ids) |node_id| try node.node_ids.append(node_id);
    const init_response = msg.into(InitOk, .{ .msg_id = node.nextId(), .in_reply_to = msg.body.msg_id });
    try node.send(init_response, alt_writer);
    node.status = .initialized;

    log.info("successfully initialized node with id: {s}", .{node.id});
}

fn shutdown(node: *Node, msg: Message(std.json.Value)) !void {
    // shutdown node and maybe deinit?? or leave it as something the runner of the node
    // does when they return from the main run loop??
    node.status = .shutdown;

    const shutdown_response = .{
        .type = "shutdown_ok",
        .msg_id = node.nextId(),
        .in_reply_to = msg.body.object.get("msg_id").?.integer,
    };
    const response = msg.into(@TypeOf(shutdown_response), shutdown_response);

    // i'd like to have the response go to a custom writer stream if its provided
    try node.reply(response);
}

/// wait and listen for messages on the network and delegate handlers to handle them.
/// this is the run loop of the node, it starts the functions that waits and reads
/// from the network and sends it off for processing.
pub fn run(node: *Node, alt_reader: anytype, alt_writer: anytype) !void {
    try node.registerMethod("shutdown", shutdown);
    try node.initializeNode(node.allocator, alt_reader, alt_writer);

    const allocator = node.arena.allocator();
    while (true) {
        if (node.status == .shutdown) return;
        const payload = try node.readBytes(alt_reader) orelse return;
        const msg = try Message(std.json.Value).decode(allocator, payload);
        try node.processMessage(msg);
    }
}

fn readBytes(node: *Node, alt_reader: anytype) !?[]u8 {
    const std_in = if ((@typeInfo(@TypeOf(alt_reader)) != .Null) and
        @hasDecl(@TypeOf(alt_reader), "read")) alt_reader else node.reader();

    node.stream_buf.clearRetainingCapacity();
    std_in.streamUntilDelimiter(node.stream_buf.writer(), '\n', null) catch |err| switch (err) {
        error.EndOfStream, error.OperationAborted => return null,
        else => {
            log.err("failed to read json stream: {}", .{err});
            return err;
        },
    };
    return node.stream_buf.items;
}

pub fn processMessage(node: *Node, msg: std.json.Parsed(Message(std.json.Value))) !void {
    const msg_type = msg.value.body.object.get("type").?.string;

    // check if there is a handler for service
    if (node.handlers.get(msg_type)) |handler| {
        defer msg.deinit();
        return handler(node, msg.value);
    }

    for (node.services.items) |service| {
        if (service.contains(msg_type)) {
            switch (service.state()) {
                .active => return service.handle(msg),
                .uninitialized, .initialized => {
                    service.start(node);
                    return service.handle(msg);
                },
                .stopped, .shutdown => return error.ServiceDown,
            }
        }
    }
}

/// send message into the network.
/// send takes an alternative writer through which to send out messages
pub fn reply(node: *Node, msg: anytype) !void {
    try node.send(msg, null);
}

/// send message into the network.
/// send takes an alternative writer through which to send out messages
pub fn send(node: *Node, msg: anytype, alt_writer: anytype) !void {
    const std_out = blk: {
        const writer_type = @TypeOf(alt_writer);
        const writer_info = @typeInfo(writer_type);

        break :blk if ((writer_info != .Null) and @hasDecl(writer_type, "write"))
            alt_writer
        else
            node.writer();
    };

    _ = blk: {
        std.json.stringify(msg, stringify_options, std_out) catch |err| break :blk err;
        _ = std_out.write("\n") catch |err| break :blk err;
        break :blk node.flush();
    } catch |err| {
        log.err("could not send json response: {}", .{err});
        return err;
    };
}

/// experimental method for sending messages to a bunch of nodes in the network
pub fn broadcast(node: *Node, msg: anytype, ids: []const []const u8) !void {
    for (ids) |id| {
        msg.dest = id;
        node.reply(msg);
    }
    node.flush() catch return;
}

/// services handle a specific workload. They keep their own state and can be
/// started and run as an independent processes. They keep state and messages
/// are communicated between services and node by a message passing mechanism.
///
/// it is an interface that can be implemented to service a particular workload
/// on the maelstrom network.
///
/// And since I am not vexed in how dynamic dispatch really work in zig, let's
/// just copy how the `std.mem.Allocator` interface is defined.
pub const Service = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// initialize the service
        start: *const fn (ctx: *anyopaque, n: *Node) void,

        /// returns true if can handle message type
        contains: *const fn (ctx: *anyopaque, msg_type: []const u8) bool,

        /// handle the messages
        handle: *const fn (ctx: *anyopaque, m: std.json.Parsed(Message(std.json.Value))) void,

        /// get the state of the handler
        state: *const fn (ctx: *anyopaque) State,

        // stop the handler and destroy any memory allocated
        stop: *const fn (ctx: *anyopaque) void,
    };

    /// TODO(joe): figure out how to start the node independently
    pub fn start(self: Service, n: *Node) void {
        return self.vtable.start(self.ptr, n);
    }

    pub fn handle(self: Service, m: std.json.Parsed(Message(std.json.Value))) void {
        return self.vtable.handle(self.ptr, m);
    }

    pub fn state(self: Service) State {
        return self.vtable.state(self.ptr);
    }

    pub fn stop(self: Service) void {
        return self.vtable.stop(self.ptr);
    }

    pub fn contains(self: Service, msg_type: []const u8) bool {
        return self.vtable.contains(self.ptr, msg_type);
    }
};

/// given a generic type and a type erased pointer to that type,
/// return a pointer that is properly aligned to the type
pub fn alignCastPtr(comptime T: type, ctx: *anyopaque) *T {
    return @ptrCast(@alignCast(ctx));
}

/// Messages are json objects routed between different nodes participating in the
/// maelstrom network. They are transmitted to through STDIN and STDOUT.
pub fn Message(comptime T: type) type {
    if (T != std.json.Value) {
        if (!@hasField(T, "msg_id") or !@hasField(T, "type"))
            @compileError(@typeName(T) ++ " must have a 'msg_id' and 'type' field");
    }
    return struct {
        const Self = @This();

        src: []const u8 = undefined,
        dest: []const u8 = undefined,

        /// Every message that comes through the wire has (or not) a body, this body
        /// contains contains the actual message. if you don't know
        /// the type of the body before hand, you can use the std.json.Value type.
        body: T,

        pub fn init(src: []const u8, dest: []const u8, payload: T) Message(T) {
            return .{ .src = src, .dest = dest, .body = payload };
        }

        /// decodeMessage unmarshals a json string into a message object, it allocate's
        /// memory which must be freed when message is no longer in use.
        ///
        /// I'll recommend an arena allocator that pass in when a request comes in and that
        /// you free when the request processing is done.
        pub fn decode(allocator: Allocator, bytes: []const u8) !std.json.Parsed(Message(T)) {
            return std.json.parseFromSlice(Message(T), allocator, bytes, parse_options);
        }

        pub fn fromValue(msg: Self, comptime P: type, allocator: std.mem.Allocator) !std.json.Parsed(P) {
            return try std.json.parseFromValue(P, allocator, msg.body, parse_options);
        }

        // create a message from individual values that make up that message. The
        // body type is supposed to be a struct with a "type" field. This function
        // allocates memory that will be hard to deallocate without an arena allocator.
        pub fn into(msg: Self, comptime P: type, payload: P) Message(P) {
            return Message(P){
                .src = msg.dest,
                .dest = msg.src,
                .body = payload,
            };
        }

        pub fn intoAlloc(msg: Self, comptime P: type, payload: P, allocator: std.mem.Allocator) !Message(P) {
            return Message(P){
                .src = try allocator.dupeZ(u8, msg.dest),
                .dest = try allocator.dupeZ(u8, msg.src),
                .body = payload,
            };
        }
    };
}

test "stringify message" {
    const Test = struct {
        type: []const u8,
        name: []const u8,
        msg_id: u64,
    };
    const test_msg = Message(Test){
        .body = .{
            .type = "test",
            .msg_id = 0,
            .name = "n1",
        },
    };
    try std.json.stringify(test_msg, .{}, std.io.getStdErr().writer());
}

test "stringify into message" {
    const Test = struct {
        type: []const u8,
        name: []const u8,
        msg_id: u64,
    };
    const test_msg = Message(Test){
        .body = .{
            .type = "test",
            .msg_id = 0,
            .name = "n1",
        },
    };
    // try std.json.stringify(test_msg, .{}, std.io.getStdErr().writer());

    try std.json.stringify(test_msg.into(Test, .{
        .type = "test",
        .msg_id = 0,
        .name = "n2",
    }), .{}, std.io.getStdErr().writer());
}

fn dump(msg: anytype) !void {
    try std.json.stringify(msg, .{}, std.io.getStdErr().writer());
    std.debug.print("\n", .{});
}

test "stringify anytype func" {
    const Test = struct {
        type: []const u8,
        name: []const u8,
        msg_id: u64,
    };
    const test_msg = Message(Test){
        .body = .{
            .type = "test",
            .msg_id = 0,
            .name = "n1",
        },
    };
    try dump(test_msg);
}

test "message into struct" {
    const json_payload =
        \\{
        \\  "src": "n1", "dest": "c1", "body": {
        \\     "msg_id": 1,
        \\     "type": "echo",
        \\     "echo": "Hello, World!"
        \\   }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Echo = struct {
        type: []const u8 = "test",
        msg_id: usize,
        echo: []const u8,
    };

    const msg = try Message(Echo).decode(arena.allocator(), json_payload);
    try testing.expect(std.mem.eql(u8, "n1", msg.value.src));
    try testing.expect(std.mem.eql(u8, "c1", msg.value.dest));
    try testing.expect(1 == msg.value.body.msg_id);
    try testing.expect(std.mem.eql(u8, "Hello, World!", msg.value.body.echo));
}

test "message into json value" {
    const json_payload =
        \\{
        \\  "src": "n1", "dest": "c1", "body": {
        \\     "msg_id": 1,
        \\     "type": "echo",
        \\     "echo": "Hello, World!"
        \\   }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const msg = try Message(std.json.Value).decode(arena.allocator(), json_payload);
    try testing.expect(std.mem.eql(u8, "n1", msg.value.src));
    try testing.expect(std.mem.eql(u8, "c1", msg.value.dest));
    try testing.expect(1 == msg.value.body.object.get("msg_id").?.integer);
    try testing.expect(std.mem.eql(u8, "Hello, World!", msg.value.body.object.get("echo").?.string));
    try testing.expect(std.mem.eql(u8, "echo", msg.value.body.object.get("type").?.string));
}

const MockService = struct {
    recv_msg: std.ArrayList(Message(std.json.Value)),
    allocator: Allocator,
    state: State = .initialized,
    node: *Node = undefined,

    pub fn init(allocator: Allocator) @This() {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *@This()) void {
        self.recv_msg.deinit();
        if (self.node != undefined) self.node.deinit();
    }

    fn getSelf(ctx: *anyopaque) *@This() {
        return Node.alignCastPtr(MockService, ctx);
    }

    fn start(ctx: *anyopaque, n: *Node) void {
        const self = getSelf(ctx);
        self.node = n;
        self.status = .active;
    }

    fn state(ctx: *anyopaque) State {
        return getSelf(ctx).state;
    }

    fn contains(_: *anyopaque, msg_type: []const u8) bool {
        return std.mem.eql(u8, msg_type, "test");
    }

    fn stop(ctx: *anyopaque) void {
        getSelf(ctx).state = .stopped;
    }

    fn handle(ctx: *anyopaque, msg: std.json.Parsed(Message(std.json.Value))) void {
        var self = getSelf(ctx);
        self.recv_msg.append(msg.value) catch unreachable;
    }
};

test "node - state transitions; initialize and shutdown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const node = try Node.init(arena.allocator());
    defer node.deinit();
    var buffer: [1024]u8 = undefined;
    var pipe = @import("Pipe.zig").init(&buffer);
    defer pipe.close();

    const init_msg =
        \\{"src": "test", "dest": "test", "body": {"type": "init", "msg_id": 0}}\n
    ;
    const shutdown_msg =
        \\{"src": "test", "dest": "test", "body": {"type": "shutdown", "msg_id": 1}}\n
    ;
    const wrote = try pipe.writer().write(init_msg ++ shutdown_msg);
    try testing.expectEqual(wrote, init_msg.len + shutdown_msg.len);
    var out_buf: [shutdown_msg.len + init_msg.len + 20]u8 = undefined;
    std.debug.print("{s}", .{try pipe.reader().readUntilDelimiter(&out_buf, '\n')});
}

// test "node - init message exchange (single thread)" {
//     // init a node and a tester
//     var arena = std.heap.arenaallocator.init(testing.allocator);
//     defer arena.deinit();
//
//     const node = try node.init(arena.allocator());
//     node.status = .shutdown;
//     defer node.deinit();
//
//     var test_svc: MockService = .{};
//     node.services.append(test_svc);
//
//     const src = "n0";
//     const dest = "z0";
//     const init_body = .{
//         .type = "test",
//         .msg_id = @as(usize, 1),
//         .node_id = "n0",
//         .node_ids = &[_][]const u8{ "n1", "n2" },
//     };
//
//     const message = Message(@TypeOf(init_body)){ .src = src, .dest = dest, .body = init_body };
//
//     // read out the response
//     var init_ok = sim.read(node.arena.allocator()) orelse unreachable;
//     try testing.expect(std.mem.eql(u8, "init_ok", init_ok.value.body.object.get("type").?.string));
//     try testing.expect(std.mem.eql(u8, "n0", init_ok.value.body.object.get("node_id").?.string));
// }

// test "node - init message exchange (multithread)" {
//     if (@import("builtin").single_threaded) return error.SkipZigTest;
//
//     const Runner = struct {
//         pub fn run(t: *Simulator, n: *Node) void {
//             while (true) {
//                 // wait on the node tester to write to pipe
//                 if (n.status == .shutdown) {
//                     t.test_done_event.set();
//                     return;
//                 }
//
//                 t.notify_send.wait();
//
//                 // process the data and send response
//                 n.runOnce(null, t.pipe.reader(), t.pipe.writer()) catch unreachable;
//
//                 // notify read the data
//                 t.wait(t.millisecond);
//                 t.notify_read.set();
//             }
//         }
//     };
//
//     var sim = Simulator{ .use_events = true };
//     var tnode = try Node.init(testing.allocator);
//     defer tnode.deinit();
//
//     const src: []const u8 = "src";
//     const dest: []const u8 = "dest";
//
//     // create a thread to send message into the network
//     var thread = try std.Thread.spawn(
//         .{},
//         Runner.run,
//         .{ &sim, tnode },
//     );
//     thread.detach();
//
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//
//     // send init message
//     const init_body = .{
//         .type = "init",
//         .msg_id = @as(i64, 1),
//         .node_id = "zerubbabel",
//         .node_ids = &[_][]const u8{ "abihud", "hannaniah" },
//     };
//
//     _ = sim.sendAndWaitToRead(
//         arena.allocator(),
//         src,
//         dest,
//         init_body,
//     ) orelse unreachable;
//
//     // then send the shutdown message now
//     const shutdown = .{ .type = "shutdown" };
//     sim.send(arena.allocator(), src, dest, shutdown);
//
//     sim.test_done_event.wait();
//     try testing.expect(tnode.status == .shutdown);
//
// }
