/// A pipe is an io.Reader and io.Writer pair. Every write into the pipe
/// is available for reading from the writer provided.
const std = @import("std");
const io = std.io;
const Mutex = std.Thread.Mutex;
const testing = std.testing;

const Self = @This();
const Error = error{ EndOfStream, OperationAborted };

mu: std.Thread.Mutex = .{},

/// buf is a slice that can written to as well as read from
buf: []u8,
wr_idx: usize = 0,
rd_idx: usize = 0,

/// read from the underlying buffer
pub fn read(self: *Self, dest: []u8) Error!usize {
    self.mu.lock();
    defer self.mu.unlock();
    _ = dest;
}

/// write to the underlying buffer
pub fn write(self: *Self, bytes: []const u8) Error!usize {
    self.mu.lock();
    defer self.mu.unlock();
    _ = bytes;
}

const Reader = io.Reader(*Self, Error, read);
const Writer = io.Writer(*Self, Error, write);

pub fn reader(self: *Self) Reader {
    return .{ .context = self };
}

pub fn writer(self: *Self) Writer {
    return .{ .context = self };
}

pub fn Pipe(buffer: []u8) Self {
    return .{ .buf = buffer };
}

test "pipe - write/read" {
    var buf: [512]u8 = undefined;
    var pipe = Pipe(&buf);

    const hello = "hello world! fuckers";

    try pipe.writer().writeAll(hello);

    var buffer: [hello.len]u8 = undefined;
    _ = try pipe.reader().read(&buffer);

    try testing.expect(std.mem.eql(u8, hello, &buffer));
}

test "pipe - different threads read/write" {
    var buf: [512]u8 = undefined;
    var pipe = Pipe(&buf);

    const hello = "hello world! fuckers";

    try pipe.writer().writeAll(hello);

    const Runner = struct {
        fn run(stream: anytype, data: []const u8) void {
            var buffer: [hello.len]u8 = undefined;
            _ = stream.read(&buffer) catch unreachable;
            testing.expect(std.mem.eql(u8, data, &buffer)) catch unreachable;
        }
    };

    var thread = try std.Thread.spawn(
        .{},
        Runner.run,
        .{ pipe.reader(), hello },
    );
    thread.join();
}

test "pipe - different threads write/read" {
    var buf: [512]u8 = undefined;
    var pipe = Pipe(&buf);

    const hello = "hello world! fuckers";

    const Runner = struct {
        fn run(stream: anytype, data: []const u8) void {
            _ = stream.writeAll(data) catch unreachable;
        }
    };

    var thread = try std.Thread.spawn(
        .{},
        Runner.run,
        .{ pipe.writer(), hello },
    );
    thread.detach();

    // wait for a while
    std.time.sleep(std.time.ns_per_ms);

    var buffer: [hello.len]u8 = undefined;
    _ = try pipe.reader().read(&buffer);
    try testing.expect(std.mem.eql(u8, hello, &buffer));
}
