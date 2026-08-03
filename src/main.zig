// src/main.zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.print("cairn: {s}\n", .{if (args.len > 1) args[1] else "no args"});
}
