const std = @import("std");
const Node = @import("Node");

pub fn main() !void {
    var node = try Node.init(std.heap.page_allocator);
    defer node.deinit();

    node.run(null, null) catch {
        std.os.exit(1);
    };
}
