//! In maelstrom, Nodes, recieve messages from STDIN and send out responses through
//! the STDOUT. This file provides code to bootstrap a node that can be built upon
//! to do some work in the maelstrom network. It also provides the initial message
//! types that are used to prepare a node for participating in the network.
const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;

const log = std.log.scoped(.Node);

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

const Node = @This();

/// standard output and input
const out = io.getStdOut().writer();
const in = io.getStdIn().reader();

/// Methods handle messages
const Method = *const fn (*Node, *Message) anyerror!void;

allocator: Allocator = undefined,
arena: std.heap.ArenaAllocator = undefined,

/// unique string identifer used to route messages to and from the node
id: []u8 = &[_]u8{},

// temp buffer for storing bytes recieved from the network
buf: []u8 = &[_]u8{},

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
services: std.StringHashMap(Service) = undefined,

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
        .buf = try allocator.alloc(u8, 1024),
        .arena = std.heap.ArenaAllocator.init(allocator),
        .node_ids = std.ArrayList([]const u8).init(allocator),

        // TODO(joe): consider not initialzing the hash maps until there is
        // something to register
        .handlers = std.StringHashMap(Method).init(allocator),
        .services = std.StringHashMap(Service).init(allocator),
    };
    return node;
}

pub fn deinit(node: *Node) void {
    // deallocate some buffers
    if (node.id.len > 0) node.allocator.free(node.id);
    if (node.buf.len > 0) node.allocator.free(node.buf);

    node.node_ids.deinit();
    node.handlers.deinit();
    node.services.deinit();

    node.arena.deinit();

    // now we obliterate the node itself
    node.allocator.destroy(node);
}

/// get the next msg_id from the node, can be called concurrently.
pub fn msg_id(node: *Node) usize {
    return @atomicRmw(usize, &node.next_id, .Add, 1, .monotonic);
}

/// register a method to handle a specific type of message
pub fn registerMethod(node: *Node, typ: []const u8, method: Method) !void {
    return node.handlers.put(typ, method);
}

/// register a service for handling a group of messages. `types` is a concatenation
/// of all the types of messages that can be handled by the the service
///
/// eg:  to register a service named `send_back` that can handle an echo, broadcast
///      and topology messages do:
///
///         `try node.registerService("echo/broadcast/topology", send_back);`
///
///     the separators can be anything or nothing
pub fn registerService(node: *Node, types: []const u8, service: Service) !void {
    return node.services.put(types, service);
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

/// wait and listen for messages on the network and delegate handlers to handle them.
/// this is the run loop of the node, it starts the functions that waits and reads
/// from the network and sends it off for processing.
pub fn run(node: *Node, alt_reader: anytype, alt_writer: anytype) !void {
    while (true) {
        if (node.status == .shutdown) return;
        try node.runOnce(node.arena.allocator(), alt_reader, alt_writer);

        // let's reset the allocator for another round of allocations. but we
        // don't want to be freeing memory in a tight loop so we retain the
        // capacity for the next round.
        //
        // why don't we have GC's over here again?? :-/
        if (@atomicLoad(usize, &node.next_id, .seq_cst) % 50 == 0) {
            _ = node.arena.reset(.retain_capacity);
        }
    }
}

/// runOnce waits patiently for messages from client/peers in the network and
/// decides where to send them.
pub fn runOnce(node: *Node, alloc: ?Allocator, alt_reader: anytype, alt_writer: anytype) !void {
    const std_in = if ((@typeInfo(@TypeOf(alt_reader)) != .Null) and
        @hasDecl(@TypeOf(alt_reader), "read")) alt_reader else node.reader();

    if (node.status == .shutdown) {
        log.info("node is down!", .{});
        return;
    }

    const allocator = alloc orelse node.arena.allocator();

    const bytes = std_in.readUntilDelimiter(node.buf, '\n') catch |err| switch (err) {
        error.EndOfStream, error.OperationAborted => return,
        else => {
            log.err("failed to read json stream: {}", .{err});
            return;
        },
    };

    // log.info("recieved message: {s}", .{bytes});

    var msg = try Message.decode(allocator, bytes);
    const msg_type = msg.getType();

    // handle init message
    if (std.mem.eql(u8, msg_type, "init")) {
        node.handleInitMessage(&msg, alt_writer) catch |err| {
            log.err("failed to initialize node: {}", .{err});
            return err;
        };
        log.info("successfully initialized node with id: {s}", .{node.id});
        return;
    } else if (std.mem.eql(u8, msg_type, "shutdown")) {
        node.status = .shutdown;
        return;
    }

    // check if there is a handler for service
    han: {
        const handler = node.handlers.get(msg_type) orelse break :han;

        // TODO: better error handling for the handlers
        handler(node, &msg) catch |err| {
            log.err("handler for {s} crashed with err: {}", .{ msg_type, err });
            return err;
        };
        return;
    }

    var service = blk: {
        var keys = node.services.keyIterator();
        while (keys.next()) |key| {
            if (std.mem.containsAtLeast(u8, key.*, 1, msg_type)) {
                break :blk node.services.get(key.*) orelse unreachable;
            }
        }
        break :blk error.NoHandler;
    } catch |err| {
        log.err("handler/service not available for {s} messages: {}", .{ msg_type, err });
        return err;
    };

    const service_state = service.state();
    if (service_state == .active or service_state == .stopped) {
        service.handle(&msg);
    } else {
        service.start(node);
        service.handle(&msg);
    }
}

/// initialize node for participating in the network
fn handleInitMessage(node: *Node, msg: *Message, alt_writer: anytype) !void {
    // set the node id
    const id = msg.get("node_id").?.string;
    node.id = try node.allocator.alloc(u8, id.len);
    @memcpy(node.id, id);
    node.status = .initialized;

    // then add the node ids of peers in the network
    const node_ids = msg.get("node_ids").?.array;
    for (node_ids.items) |node_id| try node.node_ids.append(node_id.string);

    assert(msg.remove("node_ids"));
    assert(msg.remove("node_id"));

    msg.set("type", .{ .string = "init_ok" }) catch unreachable;
    msg.dest = msg.src;
    msg.src = node.id;

    // is this what I was doing that was fucking me up????????????
    //
    // why the fuck was I deinit-ing the arena in this function that is
    // supposed to run only once in the entire lifetime of the node?
    //
    // that is why the fucking thing was segfaulting all this while???
    // JESUS! joe
    //
    // defer node.arena.deinit();

    try node.send(msg, alt_writer);
}

/// set the message's `in_reply_to` and `msg_id` fields to the appropriate values
pub fn setReplyTo(node: *Node, msg: *Message) void {
    msg.set(
        "in_reply_to",
        msg.get("msg_id").?,
    ) catch unreachable;

    msg.set("msg_id", .{ .integer = @intCast(node.msg_id()) }) catch unreachable;
}

/// send message into the network.
/// send takes an alternative writer through which to send out messages
pub fn send(node: *Node, msg: *Message, alt_writer: anytype) !void {
    const writer_type = @TypeOf(alt_writer);
    const writer_info = @typeInfo(writer_type);

    const std_out = if ((writer_info != .Null) and @hasDecl(writer_type, "write"))
        alt_writer
    else
        node.writer();

    node.setReplyTo(msg);

    // debug shit!
    // log.info(
    //     "Sending out '{s}' message, in_reply_to: {d}, msg_id: {d}",
    //     .{ msg.get("type").?.String, msg.get("in_reply_to").?.Integer, msg.get("msg_id").?.Integer },
    // );

    msg.json(std_out) catch |err| {
        log.err("could not write json out: {}", .{err});
        return;
    };

    // std_writer.writeAll(written) catch |err| {
    //     log.err("could not write into the ether: {}", .{err});
    // };

    _ = std_out.write("\n") catch return;
    if (writer_info == .Null) node.flush() catch return;
}

/// experimental method for sending messages to a bunch of nodes in the network
pub fn broadcast(node: *Node, msg: *Message, ids: []const []const u8) !void {
    const std_out = node.writer();

    msg.src = node.id;

    for (ids) |id| {
        msg.dest = id;
        // node.setReplyTo(msg);
        msg.json(std_out) catch |err| {
            log.err("could not write json out: {}", .{err});
            return;
        };
        _ = std_out.write("\n") catch return;
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

        /// handle
        handle: *const fn (ctx: *anyopaque, m: *Message) void,

        /// get the state of the handler
        state: *const fn (ctx: *anyopaque) State,

        // stop the handler and destroy any memory allocated
        // stop: *const fn state(ctx: *anyopaque) void,
    };

    // work in progress stuff, it doesn't work and its not really what I want to achieve anyways.
    // I am looking for a way to just pass the object and its type and then get the needed function
    // pointers from it
    pub fn initFromMethods(impl: anytype, start_fn: anytype, handle_fn: anytype, state_fn: anytype) Service {
        return .{
            .ptr = @ptrCast(impl),
            .vtable = &.{
                .start = @ptrCast(start_fn),
                .handle = @ptrCast(handle_fn),
                .state = @ptrCast(state_fn),
            },
        };
    }

    /// TODO(joe): figure out how to start the node independently
    pub fn start(self: Service, n: *Node) void {
        return self.vtable.start(self.ptr, n);

        // var thread = try std.Thread.spawn(
        //     .{},
        //     self.vtable.start,
        //     .{ self.ptr, n },
        // );
        // thread.detach();
    }

    pub fn handle(self: Service, m: *Message) void {
        return self.vtable.handle(self.ptr, m);
    }

    pub fn state(self: Service) State {
        return self.vtable.state(self.ptr);
    }
};

/// given a generic type and a type erased pointer to that type,
/// return a pointer that is properly aligned to the type
pub fn alignCastPtr(comptime T: type, ctx: *anyopaque) *T {
    return @ptrCast(@alignCast(ctx));
}

/// Messages are json objects routed between different nodes participating in the
/// maelstrom network. They are transmitted to through STDIN and STDOUT.
pub const Message = struct {
    const Self = @This();

    src: ?[]const u8,
    dest: ?[]const u8,

    /// Every message that comes through the wire has (or not) a body, this body
    /// is contains the data that the handlers need to do stuff.
    body: std.json.Value,

    // get a specific field of the message's body
    pub fn get(msg: Self, field: []const u8) ?std.json.Value {
        return msg.body.object.get(field);
    }

    /// set json value entry on the message body
    pub fn set(msg: *Self, field: []const u8, val: std.json.Value) !void {
        return msg.body.object.put(field, val);
    }

    /// remove json value entry from the message body
    pub fn remove(msg: *Self, field: []const u8) bool {
        return msg.body.object.swapRemove(field);
    }

    // get the body type of a message
    pub fn getType(msg: Self) []const u8 {
        return msg.get("type").?.string;
    }

    /// decodeMessage unmarshals a json string into a message object, it allocate's
    /// memory which must be freed when message is no longer in use.
    ///
    /// I'll recommend an arena allocator that pass in when a request comes in and that
    /// you free when the request processing is done.
    pub fn decode(allocator: Allocator, bytes: []const u8) !Self {
        return std.json.parseFromSliceLeaky(Message, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
            log.err("failed to parse message: {}", .{err});
            return err;
        };
    }

    // create a message from individual values that make up that message. The
    // body type is supposed to be a struct with a "type" field. This function
    // allocates memory that will be hard to deallocate without an arena allocator.
    pub fn from(
        allocator: Allocator,
        src: ?[]const u8,
        dest: ?[]const u8,
        body: anytype,
    ) !Self {

        // check if the type is actually a struct that has a "type" field
        if (@typeInfo(@TypeOf(body)) == .Struct) {
            if (std.mem.eql(u8, @field(body, "type"), "")) return error.InvalidBody;
        } else return error.InvalidBody;

        // let's do a very sad thing over here!
        // make body json
        var buffer: [512]u8 = undefined;
        var buffer_stream = std.io.fixedBufferStream(&buffer);
        try std.json.stringify(body, .{}, buffer_stream.writer());
        const payload = buffer_stream.getWritten();

        var parser = std.json.Parser.init(allocator, true);
        const tree = parser.parse(payload) catch |err| {
            log.err("failed to parse body: {}", .{err});
            return err;
        };

        return .{
            .src = src,
            .dest = dest,
            .body = tree.root,
        };
    }

    /// get the json string of a message
    pub fn json(msg: Self, out_stream: anytype) !void {
        return std.json.stringify(msg, .{}, out_stream);
    }

    /// get the json string of the message body
    pub fn jsonBody(msg: Self, out_stream: anytype) !void {
        return std.json.stringify(msg.body, .{}, out_stream);
    }
};

test "message from json string" {
    const msg =
        \\{
        \\  "src": "n1", "dest": "c1", "body": {
        \\     "msg_id": 1,
        \\     "type": "echo",
        \\     "echo": "hello there"
        \\   }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const msg_obj = try Message.decode(arena.allocator(), msg);
    try testing.expect(std.mem.eql(u8, "n1", msg_obj.src.?));
    try testing.expect(std.mem.eql(u8, "c1", msg_obj.dest.?));

    const echo = struct {
        type: []const u8,
        msg_id: usize,
        echo: []const u8,
    };

    // buffer stream that holds the json object
    var buffer: [512]u8 = undefined;
    var buffer_stream = std.io.fixedBufferStream(&buffer);
    try msg_obj.jsonBody(buffer_stream.writer());

    const payload = buffer_stream.getWritten();
    // std.debug.print("{s}\n", .{payload});

    // token stream for decoding json into echo object
    var json_stream = std.json.TokenStream.init(payload);
    const echo_msg = try std.json.parse(echo, &json_stream, .{
        .allocator = arena.allocator(),
    });
    try testing.expect(std.mem.eql(u8, "echo", echo_msg.type));
    try testing.expect(std.mem.eql(u8, "hello there", echo_msg.echo));
    try testing.expectEqual(@as(usize, 1), echo_msg.msg_id);
}

test "message from body struct" {
    const body = .{
        .type = "parts",
        .done = false,
        .node_ids = &[_][]const u8{ "joe", "thalia" },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var msg = try Message.from(arena.allocator(), "s1", "w2", body);

    try testing.expect(std.mem.eql(u8, "s1", msg.src.?));
    try testing.expect(std.mem.eql(u8, "w2", msg.dest.?));
    try testing.expect(std.mem.eql(u8, body.type, msg.getType()));
    try testing.expect(msg.get("done").?.Bool == body.done);

    const msg_ids = msg.get("node_ids").?.array;
    for (body.node_ids, msg_ids.items) |exp, val|
        try testing.expect(std.mem.eql(u8, exp, val.string));
}

// let's use this whacky pipe to tunnel messages from test to node
const Pipe = @import("Pipe.zig");

const Simulator = struct {
    const ResetEvent = std.Thread.ResetEvent;
    var pipe_buf: [1024]u8 = undefined;

    use_events: bool, // signal whether to use ResetEvents
    notify_send: ResetEvent = .{},
    notify_read: ResetEvent = .{},
    test_done_event: ResetEvent = .{},
    millisecond: u64 = std.time.ns_per_ms,
    pipe: Pipe = Pipe.Pipe(&pipe_buf), // horrible api design if you ask me

    fn send(
        t: *@This(),
        allocator: Allocator,
        src: []const u8,
        dest: []const u8,
        body: anytype,
    ) void {
        var message = Message.from(
            allocator,
            src,
            dest,
            body,
        ) catch unreachable;

        var stream = t.pipe.writer();
        message.json(stream) catch unreachable;
        _ = stream.write("\n") catch unreachable;

        if (t.use_events) t.notify_send.set();
    }

    // read something from the buffer
    fn read(t: *@This(), allocator: Allocator) ?Message {
        if (t.use_events) t.notify_read.wait();

        var buf: [512]u8 = undefined;
        while (true) {
            const bytes = t.pipe.reader().readUntilDelimiter(&buf, '\n') catch |err| switch (err) {
                error.EndOfStream, error.OperationAborted => continue,
                else => {
                    log.err("failed to read json stream: {}", .{err});
                    return null;
                },
            };

            return Message.decode(allocator, bytes) catch unreachable;
        }
        return null;
    }

    // send a message into the simulated network and wait to read the response
    // use this function only when you have use_events enabled
    fn sendAndWaitToRead(
        t: *@This(),
        allocator: Allocator,
        src: []const u8,
        dest: []const u8,
        body: anytype,
    ) ?Message {
        if (!t.use_events) return null;

        t.send(allocator, src, dest, body);
        return t.read(allocator);
    }

    pub fn wait(_: @This(), delay: u64) void {
        std.time.sleep(delay);
    }
};

test "node - init message exchange (single thread)" {
    // init a node and a tester
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try Node.init(testing.allocator);
    defer node.deinit();

    var sim = Simulator{ .use_events = false };
    const src = "n0";
    const dest = "z0";

    // send init message
    const init_body = .{
        .type = "init",
        .msg_id = @as(i64, 1),
        .node_id = "zerubbabel",
        .node_ids = &[_][]const u8{ "abihud", "hannaniah" },
    };
    sim.send(arena.allocator(), src, dest, init_body);

    // run node to process message and send response
    try node.runOnce(arena.allocator(), sim.pipe.reader(), sim.pipe.writer());

    // read out the response
    var msg = sim.read(arena.allocator()) orelse unreachable;
    try testing.expect(std.mem.eql(u8, msg.getType(), "init_ok"));
    try testing.expect(msg.get("in_reply_to").?.integer == init_body.msg_id);
    // TODO(joe): assert that the other values are correctly parsed

    // send shutdown message
    const shutdown = .{ .type = "shutdown" };
    sim.send(arena.allocator(), src, dest, shutdown);
    try node.runOnce(arena.allocator(), sim.pipe.reader(), sim.pipe.writer());

    try testing.expect(node.status == .shutdown);
}

test "node - init message exchange (multithread)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const Runner = struct {
        pub fn run(t: *Simulator, n: *Node) void {
            while (true) {
                // wait on the node tester to write to pipe
                if (n.status == .shutdown) {
                    t.test_done_event.set();
                    return;
                }

                t.notify_send.wait();

                // process the data and send response
                n.runOnce(null, t.pipe.reader(), t.pipe.writer()) catch unreachable;

                // notify read the data
                t.wait(t.millisecond);
                t.notify_read.set();
            }
        }
    };

    var sim = Simulator{ .use_events = true };
    var tnode = try Node.init(testing.allocator);
    defer tnode.deinit();

    const src: []const u8 = "src";
    const dest: []const u8 = "dest";

    // create a thread to send message into the network
    var thread = try std.Thread.spawn(
        .{},
        Runner.run,
        .{ &sim, tnode },
    );
    thread.detach();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // send init message
    const init_body = .{
        .type = "init",
        .msg_id = @as(i64, 1),
        .node_id = "zerubbabel",
        .node_ids = &[_][]const u8{ "abihud", "hannaniah" },
    };

    _ = sim.sendAndWaitToRead(
        arena.allocator(),
        src,
        dest,
        init_body,
    ) orelse unreachable;

    // then send the shutdown message now
    const shutdown = .{ .type = "shutdown" };
    sim.send(arena.allocator(), src, dest, shutdown);

    sim.test_done_event.wait();
    try testing.expect(tnode.status == .shutdown);
}
