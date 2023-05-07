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
pub fn init(allocator: Allocator) Node {
    var node = Node{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .node_ids = std.ArrayList([]const u8).init(allocator),
        .handlers = std.StringHashMap(Method).init(allocator),
    };
    return node;
}

pub fn deinit(node: *Node) void {
    // deallocate node.id if its initialized
    if (node.id.len > 0) node.allocator.free(node.id);
    node.node_ids.deinit();
    node.handlers.deinit();

    // not soo sure about this one but we keep it for now
    node.arena.deinit();
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
pub fn run(node: *Node, alt_reader: anytype) !void {
    const std_in = if ((@typeInfo(@TypeOf(alt_reader)) != .Null) and
        @hasDecl(@TypeOf(alt_reader), "read")) alt_reader else node.reader();

    var buf: [512]u8 = undefined;
    while (true) {
        if (node.status == .shutdown) {
            log.info("node is down!", .{});
            return;
        }

        var res = std_in.readUntilDelimiter(&buf, '\n') catch |err| switch (err) {
            error.EndOfStream, error.OperationAborted => continue,
            else => {
                log.err("failed to read json stream: {}", .{err});
                return;
            },
        };
        log.info("recieved message: {s}", .{res});
        try node.processMessage(res);

        // let's reset the allocator for another round of allocations. but we
        // don't want to be freeing memory in a tight loop so we retain the
        // capacity for the next round.
        //
        // why don't we have GC's over here again?? :-/
        // _ = node.arena.reset(.retain_capacity);
    }
}

/// determine what to do with packet
fn processMessage(node: *Node, bytes: []const u8) !void {
    var msg = try Message.decode(node.arena.allocator(), bytes, true);
    const msg_type = msg.getType();

    // handle init message
    if (std.mem.eql(u8, msg_type, "init")) {
        node.handleInitMessage(msg) catch |err| {
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
    try handler(node, &msg);
}

/// initialize node for participating in the network
fn handleInitMessage(node: *Node, msg: Message) !void {
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
    const res_msg = try Message.from(node.arena.allocator(), node.id, msg.src, response);
    defer node.arena.deinit();
    try node.send(res_msg);
}

/// send message into the network
pub fn send(node: *Node, msg: Message) !void {
    var std_out = node.writer();

    msg.json(std_out) catch |err| {
        log.err("could not write json out: {}", .{err});
        return;
    };

    // std_writer.writeAll(written) catch |err| {
    //     log.err("could not write into the ether: {}", .{err});
    // };

    _ = std_out.write("\n") catch return;
    node.flush() catch return;
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
const Tester = struct {
    fn sendTo(src: []const u8, dest: []const u8, body: anytype, write_to: anytype) void {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var message = Message.from(
            arena.allocator(),
            src,
            dest,
            body,
        ) catch unreachable;
        message.json(write_to) catch unreachable;
        _ = write_to.write("\n") catch unreachable;
    }
};

test "handling messages" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    // want to send message to node
    // node handles and checks for some expected fields in the message
    // all is done with a testing.allocator

    // let's use this whacky pipe to tunnel messages from test to node
    const Pipe = @import("Pipe.zig").Pipe;

    const test_message = .{
        .type = "test",
        .message = "This is a test message",
        .number = @as(i64, 20),
        .things = &[_][]const u8{ "one", "two" },
    };
    const test_src: []const u8 = "n0";
    const test_dest: []const u8 = "t0";

    var test_node = Node.init(testing.allocator);
    defer test_node.deinit();

    var allocator = testing.allocator;
    var buffer = try testing.allocator.alloc(u8, 1050);
    defer allocator.free(buffer);
    var stream = Pipe(buffer);

    const Handler = struct {
        fn handler(_: *Node, msg: *Message) !void {
            try testing.expect(std.mem.eql(u8, msg.getType(), test_message.type));
            try testing.expect(
                std.mem.eql(u8, msg.get("message").?.String, test_message.message),
            );
            try testing.expectEqual(msg.get("number").?.Integer, test_message.number);
        }
    };

    // send the data into the buffer
    Tester.sendTo(test_src, test_dest, test_message, stream.writer());
    const shutdown = .{ .type = "shutdown" };
    Tester.sendTo(test_src, test_dest, shutdown, stream.writer());

    // create a thread to send message into the network
    // var thread = try std.Thread.spawn(
    //     .{},
    //     Tester.sendTo,
    //     .{},
    // );
    // thread.detach();

    try test_node.registerMethod("test", Handler.handler);
    try test_node.run(stream.reader());
    try testing.expect(test_node.status == .shutdown);
}
