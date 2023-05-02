const std = @import("std");
const Node = @import("../Node.zig");

pub fn main() void {
    var node = Node.init(std.heap.page_allocator);
}
