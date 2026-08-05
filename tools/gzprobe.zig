// gzprobe: stdin -> gzip -> stdout. Dev/CI helper for the node cross-inflate
// test (zig-out/bin/gzprobe via `zig build`); never shipped in releases.
const std = @import("std");
const audio = @import("audio");

const MAX_INPUT: usize = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var in: std.ArrayList(u8) = .empty;
    var in_buf: [8192]u8 = undefined;
    var in_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    try in_reader.interface.appendRemaining(allocator, &in, .limited(MAX_INPUT));

    const gz = try audio.gzip(allocator, in.items);
    defer allocator.free(gz);
    try std.Io.File.stdout().writeStreamingAll(io, gz);
}
