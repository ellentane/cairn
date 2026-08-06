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
    if (args.len != 2 and args.len != 5) {
        std.debug.print("usage: wavprobe <clean|radio> [tone_low tone_high samples_per_bit]\n", .{});
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

    const wav = if (args.len == 5) blk: {
        const custom = audio.LinkProfile{
            .name = profile_name,
            .tone_low = std.fmt.parseFloat(f64, args[2]) catch {
                std.debug.print("wavprobe: bad tone_low \"{s}\"\n", .{args[2]});
                std.process.exit(1);
            },
            .tone_high = std.fmt.parseFloat(f64, args[3]) catch {
                std.debug.print("wavprobe: bad tone_high \"{s}\"\n", .{args[3]});
                std.process.exit(1);
            },
            .samples_per_bit = std.fmt.parseUnsigned(u32, args[4], 10) catch {
                std.debug.print("wavprobe: bad samples_per_bit \"{s}\"\n", .{args[4]});
                std.process.exit(1);
            },
        };
        break :blk try audio.encodeProfileCustom(allocator, in.items, idx, custom);
    } else try audio.encodeProfile(allocator, in.items, idx);
    defer allocator.free(wav);
    try std.Io.File.stdout().writeStreamingAll(io, wav);
}
