const std = @import("std");
const io = std.io;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const Self = @This();
const Error = error{
    EndOfStream,
    OperationWouldBlock,
    OperationAborted,
    PipeClosed,
    Timeout,
};

mu: Mutex = .{},
read_cond: Condition = .{},
write_cond: Condition = .{},

read_pos: usize = 0,
write_pos: usize = 0,
length: usize = 0,

is_closed: bool = false,

buffer: []u8,

pub fn init(buffer: []u8) Self {
    return .{ .buffer = buffer };
}

pub fn read(self: *Self, dest: []u8) Error!usize {
    if (dest.len == 0) return 0;

    self.mu.lock();
    defer self.mu.unlock();

    if (self.length == 0) {
        if (self.is_closed) return error.EndOfStream;
        self.read_cond.wait(&self.mu);
    }

    return self.readLocked(dest);
}

pub fn readLocked(self: *Self, dest: []u8) Error!usize {
    const to_read = @min(dest.len, self.length);

    var bytes_read: usize = 0;
    while (bytes_read < to_read) {
        dest[bytes_read] = self.buffer[self.read_pos];
        self.read_pos = (self.read_pos + 1) % self.buffer.len;
        bytes_read += 1;
    }

    self.length -= bytes_read;
    self.write_cond.signal();
    return bytes_read;
}

pub fn write(self: *Self, src: []const u8) Error!usize {
    if (src.len == 0) return 0;

    self.mu.lock();
    defer self.mu.unlock();

    if (self.is_closed) return Error.PipeClosed;

    while (self.length == self.buffer.len) {
        if (self.is_closed) return Error.PipeClosed;
        self.write_cond.wait(&self.mu);
    }

    return self.writeLocked(src);
}

pub fn writeLocked(self: *Self, src: []const u8) Error!usize {
    const avail_space = self.buffer.len - self.length;
    const to_write = @min(src.len, avail_space);

    var bytes_written: usize = 0;
    while (bytes_written < to_write) {
        self.buffer[self.write_pos] = src[bytes_written];
        self.write_pos = (self.write_pos + 1) % self.buffer.len;
        bytes_written += 1;
    }

    self.length += bytes_written;
    self.read_cond.signal();

    return bytes_written;
}

pub const Reader = io.Reader(*Self, Error, read);
pub const Writer = io.Writer(*Self, Error, write);

pub fn reader(self: *Self) Reader {
    return .{ .context = self };
}

pub fn writer(self: *Self) Writer {
    return .{ .context = self };
}

pub fn tryRead(self: *Self, dest: []u8) Error!usize {
    if (dest.len == 0) return 0;

    self.mu.lock();
    defer self.mu.unlock();

    if (self.length == 0) {
        if (self.is_closed) return Error.EndOfStream;
        return Error.OperationWouldBlock;
    }

    return self.readLocked(dest);
}

pub fn tryWrite(self: *Self, src: []const u8) Error!usize {
    if (src.len == 0) return 0;

    self.mu.lock();
    defer self.mu.unlock();

    if (self.is_closed) return error.PipeClosed;
    if (self.length == self.buffer.len) {
        return Error.OperationWouldBlock;
    }

    return self.writeLocked(src);
}

pub fn close(self: *Self) void {
    self.mu.lock();
    defer self.mu.unlock();

    self.is_closed = true;
    self.read_cond.broadcast();
    self.write_cond.broadcast();
}

const testing = std.testing;

test "Pipe - single-threaded read and write" {
    var buf: [128]u8 = undefined;
    var pipe = Self.init(&buf);

    const hello = "hello world!";

    const wrote = try pipe.tryWrite(hello);

    var buffer: [hello.len]u8 = undefined;
    _ = try pipe.tryRead(&buffer);

    try testing.expectEqual(hello.len, wrote);
    try testing.expectEqualStrings(hello, &buffer);
}

test "Pipe - Thread communication" {
    var buffer: [128]u8 = undefined;
    var pipe = Self.init(&buffer);

    const message = "Hello from another thread!";

    const Runner = struct {
        fn run(p: *Self) void {
            p.writer().writeAll(message) catch unreachable;
        }
    };

    var thread = std.Thread.spawn(.{}, Runner.run, .{&pipe}) catch unreachable;

    var read_buffer: [100]u8 = undefined;
    const bytes_read = pipe.reader().read(&read_buffer) catch unreachable;

    try testing.expectEqual(message.len, bytes_read);
    try testing.expectEqualStrings(message, read_buffer[0..bytes_read]);

    thread.join();
}

test "Pipe - multi-threaded read and write" {
    var buf: [512]u8 = undefined;
    var pipe = Self.init(&buf);

    const hello = "hello from another thread";

    try pipe.writer().writeAll(hello);

    const Runner = struct {
        fn run(stream: anytype, data: []const u8) void {
            var buffer: [hello.len]u8 = undefined;
            _ = stream.read(&buffer) catch unreachable;
            testing.expectEqualStrings(data, &buffer) catch unreachable;
        }
    };

    var thread = try std.Thread.spawn(
        .{},
        Runner.run,
        .{ pipe.reader(), hello },
    );
    thread.join();
}
