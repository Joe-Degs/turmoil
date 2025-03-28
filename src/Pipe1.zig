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

fn mask(self: Self, idx: usize) usize {
    return idx % self.buf.len;
}
fn mask2(self: Self, idx: usize) usize {
    return idx % (2 * self.buf.len);
}
fn len(self: Self) usize {
    const wrap_offset = 2 * self.buf.len * @intFromBool(self.wr_idx < self.rd_idx);
    const adjusted_wr_idx = self.wr_idx + wrap_offset;
    return adjusted_wr_idx - self.rd_idx;
}
/// read from the underlying buffer
pub fn read(self: *Self, dest: []u8) Error!usize {
    self.mu.lock();
    defer self.mu.unlock();
    if (dest.len == 0) return 0;
    var n: usize = 0;
    if (self.wr_idx == self.rd_idx) return Error.EndOfStream;
    for (dest) |*d| {
        d.* = self.buf[self.mask(self.rd_idx)];
        self.rd_idx = self.mask2(self.rd_idx + 1);
        n += 1;
    }
    return n;
}
/// write to the underlying buffer
pub fn write(self: *Self, bytes: []const u8) Error!usize {
    self.mu.lock();
    defer self.mu.unlock();
    if (bytes.len == 0) return 0;
    if (self.len() + bytes.len > self.buf.len) return error.OperationAborted;
    var n: usize = 0;
    for (bytes) |b| {
        self.buf[self.mask(self.wr_idx)] = b;
        self.wr_idx = self.mask2(self.wr_idx + 1);
        n += 1;
    }
    return n;
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
