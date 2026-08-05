// wavprobe: stdin bytes + argv[1] profile name -> frame-v2 wav (stdout).
// Dev/CI helper for the link-profile tests (zig-out/bin/wavprobe via
// `zig build wavprobe`); never shipped in releases.
const std = @import("std");
const audio = @import("audio");

const MAX_INPUT: usize = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        std.debug.print("usage: wavprobe <clean|radio>\n", .{});
        std.process.exit(2);
    }
    const profile_name = args[1];
    var profile_index: ?usize = null;
    for (audio.LINK_PROFILES, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, profile_name)) {
            profile_index = i;
            break;
        }
    }
    const idx = profile_index orelse {
        std.debug.print("wavprobe: unknown profile \"{s}\" (expected clean|radio)\n", .{profile_name});
        std.process.exit(1);
    };

    var in: std.ArrayList(u8) = .empty;
    var in_buf: [8192]u8 = undefined;
    var in_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    try in_reader.interface.appendRemaining(allocator, &in, .limited(MAX_INPUT));

    const wav = try audio.encodeProfile(allocator, in.items, idx);
    defer allocator.free(wav);
    try std.Io.File.stdout().writeStreamingAll(io, wav);
}
