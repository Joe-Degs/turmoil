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

const out = io.getStdOut().writer();
const in = io.getStdIn().reader();

const Node = @This();

/// Methods handle messages
const Method = *const fn (*Node, *Message) anyerror!void;

allocator: Allocator = undefined,
arena: std.heap.ArenaAllocator = undefined,

/// unique string identifer used to route messages to and from the node
id: []u8 = &[_]u8{},

// the id of the next message that goes out of this node
next_id: usize = 1,

/// ids of maelstrom internal clients, they send messages to nodes and expect
/// responses back.
node_ids: std.ArrayList([]const u8) = undefined,

///
handlers: std.StringHashMap(Method) = undefined,

/// t
status: enum {
    /// the server has not yet recieved an `init` request
    uninitialized,

    /// the server has recieved an `init` request and has been inited
    initialized,

    /// server has shutdown and is not handling any requests.
    shutdown,
} = .uninitialized,

/// STDOUT and STDIN streams for sending and receiving message in the network.
stdin: io.BufferedReader(4096, @TypeOf(in)) = io.bufferedReader(in),
stdout: io.BufferedWriter(4096, @TypeOf(out)) = io.bufferedWriter(out),

/// make a new node that is fit to participate in the network. An allocator is
/// needed to store things that the node relies on to do relevant work.
pub fn init(allocator: Allocator) !*Node {
    const node = try allocator.create(Node);
    node.* = Node{
        .allocator = allocator,
        .node_ids = std.ArrayList([]const u8).init(allocator),
        .handlers = std.StringHashMap(Method).init(allocator),
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    return node;
}

pub fn deinit(node: *Node) void {
    // deallocate node.id if its initialized
    if (node.id.len > 0) node.allocator.free(node.id);
    node.node_ids.deinit();
    node.handlers.deinit();

    // not soo sure about this one but we keep it for now
    if (node.arena.queryCapacity() > 0) node.arena.deinit();
    node.allocator.destroy(node);
}

pub fn msg_id(node: *Node) usize {
    return @atomicRmw(usize, &node.next_id, .Add, 1, .Monotonic);
}

/// register a method for handling a specific kind of message that flows through
/// the node.
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

/// wait and listen for messages on the network and delegate handlers to handle them.
pub fn run(node: *Node, alt_reader: anytype, alt_writer: anytype) !void {
    // var arena = std.heap.ArenaAllocator(node.allocator);
    // defer arena.deinit();

    while (true) {
        if (node.status == .shutdown) return;
        try node.runOnce(node.arena.allocator(), alt_reader, alt_writer);

        // let's reset the allocator for another round of allocations. but we
        // don't want to be freeing memory in a tight loop so we retain the
        // capacity for the next round.
        //
        // why don't we have GC's over here again?? :-/
        // _ = node.arena.reset(.retain_capacity);
    }
}

pub fn runOnce(node: *Node, alloc: ?Allocator, alt_reader: anytype, alt_writer: anytype) !void {
    const std_in = if ((@typeInfo(@TypeOf(alt_reader)) != .Null) and
        @hasDecl(@TypeOf(alt_reader), "read")) alt_reader else node.reader();

    var buf: [512]u8 = undefined;
    if (node.status == .shutdown) {
        log.info("node is down!", .{});
        return;
    }

    var allocator = alloc orelse node.arena.allocator();

    const bytes = std_in.readUntilDelimiter(&buf, '\n') catch |err| switch (err) {
        error.EndOfStream, error.OperationAborted => return,
        else => {
            log.err("failed to read json stream: {}", .{err});
            return;
        },
    };
    log.info("recieved message: {s}", .{bytes});

    var msg = try Message.decode(allocator, bytes, true);
    const msg_type = msg.getType();

    // handle init message
    if (std.mem.eql(u8, msg_type, "init")) {
        node.handleInitMessage(allocator, msg, alt_writer) catch |err| {
            log.err("failed to initialize node: {}", .{err});
            return err;
        };
        return;
    } else if (std.mem.eql(u8, msg_type, "shutdown")) {
        node.status = .shutdown;
        return;
    }

    var handler = node.handlers.get(msg_type) orelse {
        log.err("no registered method for {s} messages", .{msg_type});
        return error.NoMethod;
    };

    // TODO: better error handling for the handlers
    handler(node, &msg) catch |err| {
        log.err("handler crashed with err: {}", .{err});
        return;
    };
}

/// initialize node for participating in the network
fn handleInitMessage(node: *Node, allocator: Allocator, msg: Message, alt_writer: anytype) !void {
    // set the node id
    const id = msg.get("node_id").?.String;
    node.id = try node.allocator.alloc(u8, id.len);
    @memcpy(node.id.ptr, id.ptr, id.len);

    // then add the node ids of peers in the network
    const node_ids = msg.get("node_ids").?.Array;
    for (node_ids.items) |node_id| try node.node_ids.append(node_id.String);

    // make the body of the init response
    const response = .{
        .type = "init_ok",
        .msg_id = node.msg_id(),
        .in_reply_to = msg.get("msg_id").?.Integer,
    };

    // make and send init_ok message
    const res_msg = try Message.from(allocator, node.id, msg.src, response);

    // is this what I was doing that was fucking me up????????????
    //
    // why the fuck was I deinit-ing the arena in this function that is
    // supposed to run only once in the entire lifetime of the node?
    //
    // that is why the fucking thing was segfaulting all this while???
    // JESUS! joe
    //
    // defer node.arena.deinit();

    try node.send(res_msg, alt_writer);
}

/// send message into the network.
/// send takes an alternative writer through which to send out messages
pub fn send(node: *Node, msg: Message, alt_writer: anytype) !void {
    const writer_info = @typeInfo(@TypeOf(alt_writer));

    const std_out = if ((writer_info != .Null) and
        @hasDecl(@TypeOf(alt_writer), "write")) alt_writer else node.writer();

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

/// Messages are json objects routed between different nodes participating in the
/// maelstrom network. They are transmitted to through STDIN and STDOUT.
pub const Message = struct {
    const Self = @This();

    src: ?[]const u8,
    dest: ?[]const u8,

    /// Every message that comes through the wire has (or not) a body, this body
    /// is contains the data that the handlers need to do stuff.
    body: std.json.Value,

    /// make a message out of a parsed tree of json values
    /// It throws an invalid message error
    pub fn fromValueTree(tree: std.json.ValueTree) error{InvalidMessage}!Self {
        if (tree.root != .Object) return error.InvalidMessage;
        const object = tree.root.Object;

        // i'm pretty sure the body of the message is not optional so we check
        const body = if (object.get("body")) |obj| blk: {
            break :blk switch (obj) {
                .Object => obj,
                else => return error.InvalidMessage,
            };
        } else return error.InvalidMessage;

        assert(@TypeOf(body) == std.json.Value);

        return .{
            .src = switch (object.get("src") orelse return error.InvalidMessage) {
                .String => |str| str,
                else => null,
            },
            .dest = switch (object.get("dest") orelse return error.InvalidMessage) {
                .String => |str| str,
                else => null,
            },
            .body = body,
        };
    }

    // get a specific field of the message's body
    pub fn get(msg: Self, field: []const u8) ?std.json.Value {
        return msg.body.Object.get(field);
    }

    pub fn set(msg: *Self, key: []const u8, val: std.json.Value) !void {
        return msg.body.Object.put(key, val);
    }

    // get the body type of a message
    pub fn getType(msg: Self) []const u8 {
        return msg.get("type").?.String;
    }

    /// decodeMessage unmarshals a json string into a message object, it allocate's
    /// memory which must be freed when message is no longer in use.
    ///
    /// I'll recommend an arena allocator that pass in when a request comes in and that
    /// you free when the request processing is done.
    pub fn decode(allocator: Allocator, bytes: []const u8, copy: bool) !Self {
        var parser = std.json.Parser.init(allocator, copy);

        // log.err("got json bytes: {s}", .{bytes});

        var tree = parser.parse(bytes) catch |err| {
            log.err("failed to parse message: {}", .{err});
            return err;
        };

        return Self.fromValueTree(tree);
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
        var tree = parser.parse(payload) catch |err| {
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

    const msg_obj = try Message.decode(arena.allocator(), msg, false);
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

    const msg_ids = msg.get("node_ids").?.Array;
    for (body.node_ids, msg_ids.items) |exp, val|
        try testing.expect(std.mem.eql(u8, exp, val.String));
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
        const bytes = t.pipe.reader().readUntilDelimiter(&buf, '\n') catch |err| switch (err) {
            error.EndOfStream, error.OperationAborted => unreachable,
            else => {
                log.err("failed to read json stream: {}", .{err});
                return null;
            },
        };

        return Message.decode(allocator, bytes, true) catch unreachable;
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
    try testing.expect(msg.get("in_reply_to").?.Integer == init_body.msg_id);
    // TODO(joe): assert that the other values are correctly parsed

    // send shutdown message
    const shutdown = .{ .type = "shutdown" };
    sim.send(arena.allocator(), src, dest, shutdown);
    try node.runOnce(arena.allocator(), sim.pipe.reader(), sim.pipe.writer());

    try testing.expect(node.status == .shutdown);
}

// test "node - init message exchange (async)" {
//     if (@import("builtin").single_threaded) return error.SkipZigTest;
//
//     const Runner = struct {
//         pub fn run(t: *Tester, n: *Node) void {
//             while (true) {
//                 // wait on the node tester to write to pipe
//                 if (n.status == .shutdown) {
//                     t.test_done_event.set();
//                     return;
//                 }
//
//                 t.notify_send.wait();
//
//                 // also pause for a few
//                 t.wait(t.millisecond);
//
//                 // process the data and send response
//                 n.runOnce(t.pipe.reader(), t.pipe.writer()) catch unreachable;
//
//                 // notify read the data
//                 t.notify_read.set();
//             }
//         }
//     };
//
//     var tester = Tester{ .use_events = true };
//     const tnode = try Node.init(testing.allocator);
//
//     const src: []const u8 = "src";
//     const dest: []const u8 = "dest";
//
//     {
//         // send init message
//         const init_body = .{
//             .type = "init",
//             .msg_id = @as(i64, 1),
//             .node_id = "zerubbabel",
//             .node_ids = &[_][]const u8{ "abihud", "hannaniah" },
//         };
//         tester.sendTo(src, dest, init_body);
//     }
//
//     // create a thread to send message into the network
//     var thread = try std.Thread.spawn(
//         .{},
//         Runner.run,
//         .{ &tester, tnode },
//     );
//     thread.detach();
//
//     tester.wait(tester.millisecond);
//
//     // wait to recieve from the channel thing
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//
//     {
//         var msg = tester.readFrom(arena.allocator()) orelse unreachable;
//         try testing.expect(std.mem.eql(u8, msg.getType(), "init_ok"));
//     }
//
//     {
//
//         // then send the shutdown message now
//         const shutdown = .{ .type = "shutdown" };
//         tester.sendTo(src, dest, shutdown);
//     }
//
//     tester.test_done_event.wait();
//     try testing.expect(tnode.status == .shutdown);
//
//     tnode.deinit();
// }

// test "node - handling messages" {
//     const test_message = .{
//         .type = "test",
//         .message = "This is a test message",
//         .number = @as(i64, 20),
//         .things = &[_][]const u8{ "one", "two" },
//     };
//     const test_src: []const u8 = "n0";
//     const test_dest: []const u8 = "t0";
//
//     var test_node = Node.init(testing.allocator);
//     defer test_node.deinit();
//
//     var allocator = testing.allocator;
//     var buffer = try testing.allocator.alloc(u8, 1050);
//     defer allocator.free(buffer);
//
//     const Handler = struct {
//         fn handler(_: *Node, msg: *Message) !void {
//             try testing.expect(std.mem.eql(u8, msg.getType(), test_message.type));
//             try testing.expect(
//                 std.mem.eql(u8, msg.get("message").?.String, test_message.message),
//             );
//             try testing.expectEqual(msg.get("number").?.Integer, test_message.number);
//         }
//     };
//
//     // send the data into the buffer
//     var tester = Tester{};
//     tester.sendTo(test_src, test_dest, test_message);
//     const shutdown = .{ .type = "shutdown" };
//     tester.sendTo(test_src, test_dest, shutdown);
//
//     try test_node.registerMethod("test", Handler.handler);
//     try test_node.run(tester.pipe.reader(), null);
//     try testing.expect(test_node.status == .shutdown);
// }
