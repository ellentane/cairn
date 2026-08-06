// Cairn audio FSK encoder: index.html bytes -> 16-bit PCM mono WAV.
// v1 link: 19200 Hz, mark 1200 Hz (bit 1), space 2400 Hz (bit 0), 8 samples/bit = 2400 bps.
// v1 frame: preamble 0xAA x64, u32le length, payload, CRC-32/ISO-HDLC.
// v2 frame (encodeProfile): go cue, preamble 0xAA x96, sync word, gzip'd data
// region with RS(255,223) depth-16 interleave bitstream, stop tone; the link
// (tones, samples/bit) is selected from LINK_PROFILES.
// Phase-continuous carrier: tone phase carries across bit boundaries.
const std = @import("std");
const flate = std.compress.flate;

pub const SAMPLE_RATE: u32 = 19200;
const MARK_HZ: f64 = 1200.0;
const SPACE_HZ: f64 = 2400.0;
const SAMPLES_PER_BIT: u32 = 8;
const PREAMBLE_LEN: usize = 64;

// v2 link profiles. tests/link_profiles.json mirrors this table; the zig test
// and tests/link_profiles_test.js both pin the two sides against each other.
pub const LinkProfile = struct {
    name: []const u8,
    tone_low: f64,        // Hz (mark, bit 1)
    tone_high: f64,       // Hz (space, bit 0)
    samples_per_bit: u32, // @ 19200 Hz encoder rate
};
pub const LINK_PROFILES = [_]LinkProfile{
    .{ .name = "clean", .tone_low = 1200, .tone_high = 2400, .samples_per_bit = 8 },
    .{ .name = "radio", .tone_low = 1200, .tone_high = 2000, .samples_per_bit = 12 },
};
pub const SYNC_WORD: u32 = 0xD3A94E57;
pub const PREAMBLE_BYTES: usize = 96;
pub const GO_CUE_HZ: f64 = 400.0;
pub const GO_CUE_SECS: f64 = 1.5;
pub const STOP_TONE_HZ: f64 = 800.0;
pub const STOP_TONE_SECS: f64 = 0.5;
pub const RS_DATA_BLOCK: usize = 223;
pub const RS_BLOCK: usize = 255;
pub const INTERLEAVE_DEPTH: usize = 16;
pub const PAD_GROUP: usize = INTERLEAVE_DEPTH * RS_DATA_BLOCK; // 3568

pub const AudioError = error{ OutOfMemory, TooLarge };

pub fn crc32IsoHdlc(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc ^= byte;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            const mask: u32 = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB88320 & mask);
        }
    }
    return ~crc;
}

fn tone(allocator: std.mem.Allocator, out: *std.ArrayList(i16), phase: *f64, freq: f64, samples: usize) !void {
    var i: usize = 0;
    while (i < samples) : (i += 1) {
        const v = @as(i16, @intFromFloat(@round(12000.0 * @sin(phase.*))));
        try out.append(allocator, v);
        phase.* += 2.0 * std.math.pi * freq / @as(f64, @floatFromInt(SAMPLE_RATE));
        if (phase.* > 2.0 * std.math.pi) phase.* -= 2.0 * std.math.pi;
    }
}

fn bitTone(allocator: std.mem.Allocator, out: *std.ArrayList(i16), phase: *f64, bit: u1) !void {
    try tone(allocator, out, phase, if (bit == 1) MARK_HZ else SPACE_HZ, SAMPLES_PER_BIT);
}

fn bitToneAt(allocator: std.mem.Allocator, out: *std.ArrayList(i16), phase: *f64, bit: u1, profile: LinkProfile) !void {
    try tone(allocator, out, phase, if (bit == 1) profile.tone_low else profile.tone_high, profile.samples_per_bit);
}

fn bitBytes(allocator: std.mem.Allocator, out: *std.ArrayList(i16), phase: *f64, data: []const u8, profile: LinkProfile) !void {
    for (data) |b| {
        var k: u32 = 0;
        while (k < 8) : (k += 1) {
            try bitToneAt(allocator, out, phase, @intCast((b >> @intCast(7 - k)) & 1), profile);
        }
    }
}

// Frame v2 encoder (audio relay v2). Wire layout: go cue (400 Hz) | preamble
// 0xAA x96 | sync word (32 bits MSB-first) | data bits | stop tone (800 Hz).
// Data region on the wire: [profile u8][compressed_len u32le][gzip payload][crc
// u32le over the region], zero-padded to a PAD_GROUP multiple, RS(255,223)
// encoded per 223-byte block, interleaved depth-16 row-major. Bits are MSB
// first; bit 1 -> profile.tone_low, bit 0 -> profile.tone_high.
pub fn encodeProfile(allocator: std.mem.Allocator, payload: []const u8, profile_index: usize) ![]u8 {
    if (profile_index >= LINK_PROFILES.len) return error.BadProfile;
    return encodeProfileCustom(allocator, payload, profile_index, LINK_PROFILES[profile_index]);
}

// Like encodeProfile but with custom modulation constants (used by the channel
// simulator's constant sweep; the profile byte stays the standard index so the
// decoder's profile detection is unchanged).
pub fn encodeProfileCustom(allocator: std.mem.Allocator, payload: []const u8, profile_index: usize, custom: LinkProfile) ![]u8 {
    if (profile_index >= LINK_PROFILES.len) return error.BadProfile;
    const profile = custom;

    const compressed = try gzip(allocator, payload);
    defer allocator.free(compressed);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    try data.append(allocator, @intCast(profile_index));
    try appendU32le(allocator, &data, @intCast(compressed.len));
    try data.appendSlice(allocator, compressed);
    try appendU32le(allocator, &data, crc32IsoHdlc(data.items));

    // Zero-pad the region to a PAD_GROUP multiple (3568 = 16 * 223). The block
    // count is then a multiple of 16, so every interleave group is full and no
    // group-level padding codewords ever appear on the wire. The last block's
    // tail is zero-fill that the decoder trims via compressed_len.
    const padded_len = ((data.items.len + PAD_GROUP - 1) / PAD_GROUP) * PAD_GROUP;
    const block_count = padded_len / RS_DATA_BLOCK;
    std.debug.assert(block_count % INTERLEAVE_DEPTH == 0);

    var codewords: std.ArrayList([RS_BLOCK]u8) = .empty;
    defer codewords.deinit(allocator);
    try codewords.ensureTotalCapacity(allocator, block_count);
    var i: usize = 0;
    while (i < block_count) : (i += 1) {
        var block: [RS_DATA_BLOCK]u8 = .{0} ** RS_DATA_BLOCK;
        const off = i * RS_DATA_BLOCK;
        if (off < data.items.len) {
            const n = @min(RS_DATA_BLOCK, data.items.len - off);
            @memcpy(block[0..n], data.items[off .. off + n]);
        }
        codewords.appendAssumeCapacity(rsEncode(&block));
    }

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    var g: usize = 0;
    while (g < codewords.items.len) : (g += INTERLEAVE_DEPTH) {
        var group = try interleave16(allocator, codewords.items[g .. g + INTERLEAVE_DEPTH]);
        defer group.deinit(allocator);
        try wire.appendSlice(allocator, group.items);
    }

    var samples: std.ArrayList(i16) = .empty;
    defer samples.deinit(allocator);
    var phase: f64 = 0.0;
    const cue_samples = @as(usize, @intFromFloat(GO_CUE_SECS * @as(f64, @floatFromInt(SAMPLE_RATE))));
    const stop_samples = @as(usize, @intFromFloat(STOP_TONE_SECS * @as(f64, @floatFromInt(SAMPLE_RATE))));
    try tone(allocator, &samples, &phase, GO_CUE_HZ, cue_samples);
    var b: usize = 0;
    while (b < PREAMBLE_BYTES) : (b += 1) try bitBytes(allocator, &samples, &phase, &.{0xAA}, profile);
    var sync_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &sync_bytes, SYNC_WORD, .big);
    try bitBytes(allocator, &samples, &phase, &sync_bytes, profile);
    try bitBytes(allocator, &samples, &phase, wire.items, profile);
    try tone(allocator, &samples, &phase, STOP_TONE_HZ, stop_samples);

    const data_bytes = samples.items.len * 2;
    var wav: std.ArrayList(u8) = .empty;
    errdefer wav.deinit(allocator);
    try appendWavHeader(allocator, &wav, data_bytes);
    for (samples.items) |s| {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(i16, &tmp, s, .little);
        try wav.appendSlice(allocator, &tmp);
    }
    return wav.toOwnedSlice(allocator);
}

fn appendWavHeader(allocator: std.mem.Allocator, wav: *std.ArrayList(u8), data_bytes: usize) !void {
    try wav.appendSlice(allocator, "RIFF");
    try appendU32le(allocator, wav, @intCast(36 + data_bytes));
    try wav.appendSlice(allocator, "WAVE");
    try wav.appendSlice(allocator, "fmt ");
    try appendU32le(allocator, wav, 16);
    try appendU16le(allocator, wav, 1);
    try appendU16le(allocator, wav, 1);
    try appendU32le(allocator, wav, SAMPLE_RATE);
    try appendU32le(allocator, wav, SAMPLE_RATE * 2);
    try appendU16le(allocator, wav, 2);
    try appendU16le(allocator, wav, 16);
    try wav.appendSlice(allocator, "data");
    try appendU32le(allocator, wav, @intCast(data_bytes));
}

pub fn encode(allocator: std.mem.Allocator, payload: []const u8) AudioError![]u8 {
    const frame_len = PREAMBLE_LEN + 4 + payload.len + 4;
    const total_bits = frame_len * 8;
    const total_samples = total_bits * SAMPLES_PER_BIT;
    const data_bytes = total_samples * 2;

    var wav: std.ArrayList(u8) = .empty;
    errdefer wav.deinit(allocator);

    try appendWavHeader(allocator, &wav, data_bytes);

    var samples: std.ArrayList(i16) = .empty;
    defer samples.deinit(allocator);
    var phase: f64 = 0.0;

    var i: usize = 0;
    while (i < PREAMBLE_LEN) : (i += 1) {
        const b: u8 = 0xAA;
        var k: u32 = 0;
        while (k < 8) : (k += 1) {
            try bitTone(allocator, &samples, &phase, @intCast((b >> @intCast(7 - k)) & 1));
        }
    }
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(payload.len), .little);
    for (len_bytes) |b| {
        var k: u32 = 0;
        while (k < 8) : (k += 1) try bitTone(allocator, &samples, &phase, @intCast((b >> @intCast(7 - k)) & 1));
    }
    for (payload) |b| {
        var k: u32 = 0;
        while (k < 8) : (k += 1) try bitTone(allocator, &samples, &phase, @intCast((b >> @intCast(7 - k)) & 1));
    }
    const crc = crc32IsoHdlc(payload);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc, .little);
    for (crc_bytes) |b| {
        var k: u32 = 0;
        while (k < 8) : (k += 1) try bitTone(allocator, &samples, &phase, @intCast((b >> @intCast(7 - k)) & 1));
    }

    for (samples.items) |s| {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(i16, &tmp, s, .little);
        try wav.appendSlice(allocator, &tmp);
    }
    return wav.toOwnedSlice(allocator);
}

fn appendU32le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try out.appendSlice(allocator, &tmp);
}

fn appendU16le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, v, .little);
    try out.appendSlice(allocator, &tmp);
}

// Reed-Solomon (255,223) systematic encoder (v2 audio relay). Parameterization
// matches python reedsolo and the JS decoder (src/decoder.js): GF(2^8) prim
// 0x11D, alpha=2, 32 roots alpha^0..alpha^31 (fcr=0), codeword = data || parity,
// polynomial bytes highest-degree-first. Pinned parity vectors live in
// tests/rs_vectors.js (auditable generator in a comment there); the zig test
// below cross-checks byte-for-byte against them.
const RS_N = RS_BLOCK;
const RS_K = RS_DATA_BLOCK;
const RS_NSYM = RS_BLOCK - RS_DATA_BLOCK; // 32

const GF_EXP: [512]u8 = blk: {
    var exp: [512]u8 = undefined;
    var x: u16 = 1;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        exp[i] = @intCast(x);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11D;
    }
    i = 255;
    while (i < 512) : (i += 1) exp[i] = exp[i - 255];
    break :blk exp;
};

const GF_LOG: [256]u8 = blk: {
    var log: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        log[GF_EXP[i]] = @intCast(i);
    }
    break :blk log;
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return GF_EXP[@as(usize, GF_LOG[a]) + GF_LOG[b]];
}

fn gfPow(a: u8, p: i32) u8 {
    const e: i32 = @as(i32, GF_LOG[a]) * p;
    const m: i32 = @mod(e, 255);
    return GF_EXP[@intCast(m)];
}

// generator polynomial g(x) = prod (x - alpha^i), i in 0..31, highest-degree-first
const RS_GEN: [RS_NSYM + 1]u8 = blk: {
    @setEvalBranchQuota(100000);
    var g: [RS_NSYM + 1]u8 = .{0} ** (RS_NSYM + 1);
    var len: usize = 1;
    g[0] = 1;
    var i: usize = 0;
    while (i < RS_NSYM) : (i += 1) {
        var next: [RS_NSYM + 1]u8 = .{0} ** (RS_NSYM + 1);
        var gi: usize = 0;
        while (gi < len) : (gi += 1) {
            next[gi] ^= g[gi];
            next[gi + 1] ^= gfMul(g[gi], gfPow(2, @intCast(i)));
        }
        g = next;
        len += 1;
    }
    break :blk g;
};

// 223 bytes in -> 255-byte codeword (data || parity). Caller guarantees
// data.len == 223. Mirrors the JS encoder byte-for-byte (pinned vectors).
pub fn rsEncode(data: []const u8) [RS_N]u8 {
    var out: [RS_N]u8 = .{0} ** RS_N;
    @memcpy(out[0..RS_K], data);
    var i: usize = 0;
    while (i < RS_K) : (i += 1) {
        const coef = out[i];
        if (coef != 0) {
            var j: usize = 1;
            while (j <= RS_NSYM) : (j += 1) {
                out[i + j] ^= gfMul(RS_GEN[j], coef);
            }
        }
    }
    @memcpy(out[0..RS_K], data); // synthetic division clobbers the message region
    return out;
}

// Depth-16 interleaver, wire order row-major: c0[0], c1[0], ..., c15[0],
// c0[1], ... (wire position b*16 + k = codeword k, byte index b).
pub fn interleave16(allocator: std.mem.Allocator, blocks: []const [RS_N]u8) !std.ArrayList(u8) {
    std.debug.assert(blocks.len == INTERLEAVE_DEPTH);
    var wire: std.ArrayList(u8) = .empty;
    errdefer wire.deinit(allocator);
    try wire.ensureTotalCapacity(allocator, INTERLEAVE_DEPTH * RS_N);
    var b: usize = 0;
    while (b < RS_N) : (b += 1) {
        for (blocks) |block| try wire.append(allocator, block[b]);
    }
    return wire;
}

// gzip payload path (v2 audio relay): std.compress.flate with the .gzip
// container, zlib-default level 6. NOTE (zig 0.16.0): the flate DECOMPRESSOR
// parses the gzip trailer but does not verify it — WrongGzipChecksum /
// WrongGzipSize are declared in the Container error set but never raised —
// so gunzip() verifies CRC-32/ISIZE itself (crc32IsoHdlc IS the gzip CRC-32:
// same reflected 0xEDB88320 polynomial, init/xorout 0xFFFFFFFF).
// Compress.init asserts a >= 8-byte output buffer (Allocating grows) and a
// >= max_window_len (64 KB) window; the Compress struct itself is ~224 KB.
pub fn gzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, 128);
    defer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&out.writer, &window, .gzip, .level_6);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

pub fn gunzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var d = flate.Decompress.init(&in, .gzip, &.{});
    _ = try d.reader.streamRemaining(&out.writer);
    const footer = data[in.seek - 8 .. in.seek];
    const want_crc = std.mem.readInt(u32, footer[0..4], .little);
    const want_size = std.mem.readInt(u32, footer[4..8], .little);
    if (crc32IsoHdlc(out.written()) != want_crc) return error.WrongGzipChecksum;
    if (@as(u32, @truncate(out.written().len)) != want_size) return error.WrongGzipSize;
    return out.toOwnedSlice();
}

test "crc32 iso-hdlc test vector" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32IsoHdlc("123456789"));
}

test "wav structure" {
    const wav = try encode(std.testing.allocator, "hi");
    defer std.testing.allocator.free(wav);
    try std.testing.expectEqualSlices(u8, "RIFF", wav[0..4]);
    try std.testing.expectEqualSlices(u8, "WAVE", wav[8..12]);
    try std.testing.expectEqualSlices(u8, "fmt ", wav[12..16]);
    try std.testing.expectEqualSlices(u8, "data", wav[36..40]);
    try std.testing.expect((wav.len - 44) % 2 == 0);
}

test "rs gf tables are self-consistent" {
    try std.testing.expectEqual(@as(u8, 1), GF_EXP[255]);
    for (0..255) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), GF_LOG[GF_EXP[i]]);
    for (1..256) |v| try std.testing.expectEqual(@as(u8, @intCast(v)), GF_EXP[GF_LOG[v]]);
}

test "rs encode parity matches pinned vector 1 (tests/rs_vectors.js)" {
    const pinned = [32]u8{
        239, 7, 171, 13, 252, 231, 26, 60, 232, 218, 129, 162, 52, 198, 198, 31,
        187, 30, 222, 146, 76, 130, 254, 114, 123, 65, 163, 215, 127, 99, 237, 65,
    };
    var data: [RS_K]u8 = undefined;
    for (0..RS_K) |i| data[i] = @intCast((i * 7 + 3) & 0xff);
    const cw = rsEncode(&data);
    try std.testing.expectEqualSlices(u8, &pinned, cw[RS_K..RS_N]);
    try std.testing.expectEqualSlices(u8, &data, cw[0..RS_K]);
}

test "rs encode parity matches pinned vector 3 data2 (tests/rs_vectors.js)" {
    const pinned2 = [32]u8{
        192, 41, 160, 57, 52, 134, 244, 107, 116, 52, 221, 238, 177, 126, 17, 184,
        190, 10, 93, 175, 42, 149, 242, 227, 218, 73, 90, 20, 164, 233, 166, 172,
    };
    var data2: [RS_K]u8 = undefined;
    for (0..RS_K) |i| data2[i] = @intCast((i * 13 + 7) & 0xff);
    const cw = rsEncode(&data2);
    try std.testing.expectEqualSlices(u8, &pinned2, cw[RS_K..RS_N]);
    try std.testing.expectEqualSlices(u8, &data2, cw[0..RS_K]);
}

test "rs encode matches js parity for full data vector" {
    var data: [RS_K]u8 = undefined;
    for (0..RS_K) |i| data[i] = @intCast((i * 7 + 3) & 0xff);
    const cw = rsEncode(&data);
    // byte 223 onward must equal the pinned parity (same vector as above);
    // syndromes must vanish at all 32 roots alpha^0..alpha^31
    var i: usize = 0;
    while (i < RS_NSYM) : (i += 1) {
        var y: u8 = 0;
        for (cw) |byte| y = gfMul(y, gfPow(2, @intCast(i))) ^ byte;
        try std.testing.expectEqual(@as(u8, 0), y);
    }
}

test "gzip emits the 1f 8b 08 header" {
    const gz = try gzip(std.testing.allocator, "hi");
    defer std.testing.allocator.free(gz);
    try std.testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), gz[1]);
    try std.testing.expectEqual(@as(u8, 0x08), gz[2]);
}

fn gzipRoundTrip(payload: []const u8) !void {
    const gz = try gzip(std.testing.allocator, payload);
    defer std.testing.allocator.free(gz);
    const back = try gunzip(std.testing.allocator, gz);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualSlices(u8, payload, back);
}

test "gzip round-trip: empty and 1-byte payloads" {
    try gzipRoundTrip("");
    try gzipRoundTrip("x");
}

test "gzip round-trip: 40 KB pseudo-random payload" {
    var data: [40 * 1024]u8 = undefined;
    var s: u32 = 0x9E3779B9;
    for (&data) |*b| {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        b.* = @truncate(s);
    }
    try gzipRoundTrip(&data);
}

test "gzip round-trip: 40 KB repetitive payload, compresses hard" {
    const data: [40 * 1024]u8 = @splat('a');
    try gzipRoundTrip(&data);
    const gz = try gzip(std.testing.allocator, &data);
    defer std.testing.allocator.free(gz);
    try std.testing.expect(gz.len < 1024);
}

test "gunzip rejects corrupted trailer bytes" {
    const gz = try gzip(std.testing.allocator, "hello hello hello");
    defer std.testing.allocator.free(gz);
    gz[gz.len - 1] ^= 0xFF;
    try std.testing.expectError(error.WrongGzipSize, gunzip(std.testing.allocator, gz));
    gz[gz.len - 5] ^= 0xFF;
    try std.testing.expectError(error.WrongGzipChecksum, gunzip(std.testing.allocator, gz));
}

test "interleave16 wire order row-major" {
    var blocks: [16][RS_N]u8 = undefined;
    for (0..16) |k| {
        for (0..RS_N) |b| blocks[k][b] = @intCast((k * RS_N + b) & 0xff);
    }
    var wire = try interleave16(std.testing.allocator, &blocks);
    defer wire.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 16 * RS_N), wire.items.len);
    for (0..16) |k| {
        try std.testing.expectEqual(blocks[k][0], wire.items[k]);
        try std.testing.expectEqual(blocks[k][1], wire.items[16 + k]);
        try std.testing.expectEqual(blocks[k][RS_N - 1], wire.items[(RS_N - 1) * 16 + k]);
    }
}

// ---- frame-v2 test helpers (inline I/Q correlators; the JS side mirrors
// these in tests/link_profiles_test.js via decoder.demodIQ) ----

fn samplesOf(allocator: std.mem.Allocator, wav: []const u8) ![]i16 {
    const out = try allocator.alloc(i16, (wav.len - 44) / 2);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const two: [2]u8 = wav[44 + i * 2 ..][0..2].*;
        out[i] = std.mem.readInt(i16, &two, .little);
    }
    return out;
}

fn testDemod(allocator: std.mem.Allocator, samples: []const i16, spb: u32, low_hz: f64, high_hz: f64) !std.ArrayList(u1) {
    var bits: std.ArrayList(u1) = .empty;
    var t: usize = 0;
    while (t + spb <= samples.len) : (t += spb) {
        var il: f64 = 0;
        var ql: f64 = 0;
        var ih: f64 = 0;
        var qh: f64 = 0;
        var k: usize = 0;
        while (k < spb) : (k += 1) {
            const tt = t + k;
            const v = @as(f64, @floatFromInt(samples[tt]));
            const al = 2.0 * std.math.pi * low_hz * @as(f64, @floatFromInt(tt)) / @as(f64, @floatFromInt(SAMPLE_RATE));
            const ah = 2.0 * std.math.pi * high_hz * @as(f64, @floatFromInt(tt)) / @as(f64, @floatFromInt(SAMPLE_RATE));
            il += v * @cos(al);
            ql += v * @sin(al);
            ih += v * @cos(ah);
            qh += v * @sin(ah);
        }
        const ml = @sqrt(il * il + ql * ql);
        const mh = @sqrt(ih * ih + qh * qh);
        try bits.append(allocator, if (ml > mh) @as(u1, 1) else 0);
    }
    return bits;
}

fn testCorrelate(samples: []const i16, off: usize, window: usize, freq: f64) f64 {
    var i: f64 = 0;
    var q: f64 = 0;
    var k: usize = 0;
    while (k < window) : (k += 1) {
        const tt = off + k;
        const v = @as(f64, @floatFromInt(samples[tt]));
        const ang = 2.0 * std.math.pi * freq * @as(f64, @floatFromInt(tt)) / @as(f64, @floatFromInt(SAMPLE_RATE));
        i += v * @cos(ang);
        q += v * @sin(ang);
    }
    return @sqrt(i * i + q * q);
}

fn testBitsToBytes(bits: []const u1, start: usize, out: []u8) void {
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        var b: u8 = 0;
        var k: usize = 0;
        while (k < 8) : (k += 1) b = (b << 1) | bits[start + i * 8 + k];
        out[i] = b;
    }
}

fn testBitsToU32(bits: []const u1, start: usize) u32 {
    var v: u32 = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) v = (v << 1) | bits[start + i];
    return v;
}

const LinkProfilesJson = struct {
    profiles: []struct {
        name: []const u8,
        tone_low: f64,
        tone_high: f64,
        samples_per_bit: u32,
    },
    sync_word: u32,
    preamble_bytes: usize,
    go_cue_hz: f64,
    go_cue_secs: f64,
    stop_tone_hz: f64,
    stop_tone_secs: f64,
    sample_rate: u32,
    rs_data_block: usize,
    rs_block: usize,
    interleave_depth: usize,
};

test "link profile constants match tests/link_profiles.json" {
    const json_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/link_profiles.json", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(json_text);
    var parsed = try std.json.parseFromSlice(LinkProfilesJson, std.testing.allocator, json_text, .{});
    defer parsed.deinit();
    const j = parsed.value;

    // pinned literals (parity anchor independent of both the table and the file)
    try std.testing.expectEqual(@as(u32, 0xD3A94E57), SYNC_WORD);
    try std.testing.expectEqual(@as(u32, 3551088215), 0xD3A94E57);
    try std.testing.expectEqual(@as(f64, 400.0), GO_CUE_HZ);
    try std.testing.expectEqual(@as(f64, 1.5), GO_CUE_SECS);
    try std.testing.expectEqual(@as(f64, 800.0), STOP_TONE_HZ);
    try std.testing.expectEqual(@as(f64, 0.5), STOP_TONE_SECS);
    try std.testing.expectEqual(@as(usize, 96), PREAMBLE_BYTES);
    try std.testing.expectEqual(@as(u32, 19200), SAMPLE_RATE);
    try std.testing.expectEqual(@as(usize, 223), RS_DATA_BLOCK);
    try std.testing.expectEqual(@as(usize, 255), RS_BLOCK);
    try std.testing.expectEqual(@as(usize, 16), INTERLEAVE_DEPTH);
    try std.testing.expectEqual(@as(usize, 3568), PAD_GROUP);

    try std.testing.expectEqual(SYNC_WORD, j.sync_word);
    try std.testing.expectEqual(PREAMBLE_BYTES, j.preamble_bytes);
    try std.testing.expectEqual(GO_CUE_HZ, j.go_cue_hz);
    try std.testing.expectEqual(GO_CUE_SECS, j.go_cue_secs);
    try std.testing.expectEqual(STOP_TONE_HZ, j.stop_tone_hz);
    try std.testing.expectEqual(STOP_TONE_SECS, j.stop_tone_secs);
    try std.testing.expectEqual(SAMPLE_RATE, j.sample_rate);
    try std.testing.expectEqual(RS_DATA_BLOCK, j.rs_data_block);
    try std.testing.expectEqual(RS_BLOCK, j.rs_block);
    try std.testing.expectEqual(INTERLEAVE_DEPTH, j.interleave_depth);

    try std.testing.expectEqual(@as(usize, LINK_PROFILES.len), j.profiles.len);
    for (LINK_PROFILES, j.profiles) |p, jp| {
        try std.testing.expectEqualStrings(p.name, jp.name);
        try std.testing.expectEqual(p.tone_low, jp.tone_low);
        try std.testing.expectEqual(p.tone_high, jp.tone_high);
        try std.testing.expectEqual(p.samples_per_bit, jp.samples_per_bit);
    }
    try std.testing.expectEqual(@as(f64, 1200), LINK_PROFILES[0].tone_low);
    try std.testing.expectEqual(@as(f64, 2400), LINK_PROFILES[0].tone_high);
    try std.testing.expectEqual(@as(u32, 8), LINK_PROFILES[0].samples_per_bit);
    try std.testing.expectEqual(@as(f64, 1200), LINK_PROFILES[1].tone_low);
    try std.testing.expectEqual(@as(f64, 2000), LINK_PROFILES[1].tone_high);
    try std.testing.expectEqual(@as(u32, 12), LINK_PROFILES[1].samples_per_bit);
    try std.testing.expectEqualStrings("clean", LINK_PROFILES[0].name);
    try std.testing.expectEqualStrings("radio", LINK_PROFILES[1].name);
}

test "v2 frame structure: header, go cue, preamble, sync word, stop tone" {
    const wav = try encodeProfile(std.testing.allocator, "v2 structure probe", 0);
    defer std.testing.allocator.free(wav);
    try std.testing.expectEqualSlices(u8, "RIFF", wav[0..4]);
    try std.testing.expectEqualSlices(u8, "WAVE", wav[8..12]);
    try std.testing.expectEqualSlices(u8, "fmt ", wav[12..16]);
    try std.testing.expectEqualSlices(u8, "data", wav[36..40]);

    const samples = try samplesOf(std.testing.allocator, wav);
    defer std.testing.allocator.free(samples);
    const data_bytes = std.mem.readInt(u32, wav[40..44][0..4], .little);
    try std.testing.expectEqual(@as(u32, @intCast(samples.len * 2)), data_bytes);
    try std.testing.expectEqual(wav.len - 44, samples.len * 2);

    // go cue: first GO_CUE_SECS * 19200 samples are 400 Hz (check start and mid)
    const cue_samples: usize = @intFromFloat(GO_CUE_SECS * @as(f64, @floatFromInt(SAMPLE_RATE)));
    const stop_samples: usize = @intFromFloat(STOP_TONE_SECS * @as(f64, @floatFromInt(SAMPLE_RATE)));
    try std.testing.expectEqual(@as(usize, 28800), cue_samples);
    try std.testing.expectEqual(@as(usize, 9600), stop_samples);
    const window: usize = 960;
    const corr_ref = 12000.0 * @as(f64, @floatFromInt(window)) / 2.0;
    try std.testing.expect(testCorrelate(samples, 0, window, GO_CUE_HZ) > 0.8 * corr_ref);
    try std.testing.expect(testCorrelate(samples, cue_samples / 2, window, GO_CUE_HZ) > 0.8 * corr_ref);
    try std.testing.expect(testCorrelate(samples, 0, window, STOP_TONE_HZ) < 0.2 * corr_ref);
    try std.testing.expect(testCorrelate(samples, 0, window, LINK_PROFILES[0].tone_low) < 0.2 * corr_ref);
    try std.testing.expect(testCorrelate(samples, 0, window, LINK_PROFILES[0].tone_high) < 0.2 * corr_ref);

    // preamble bytes 0xAA, then the sync word at the right bit offset
    const profile = LINK_PROFILES[0];
    var bits = try testDemod(std.testing.allocator, samples, profile.samples_per_bit, profile.tone_low, profile.tone_high);
    defer bits.deinit(std.testing.allocator);
    const cue_bits = cue_samples / profile.samples_per_bit;
    const pre_start = cue_bits;
    for (0..PREAMBLE_BYTES) |pb| {
        var b: u8 = 0;
        for (0..8) |k| b = (b << 1) | bits.items[pre_start + pb * 8 + k];
        try std.testing.expectEqual(@as(u8, 0xAA), b);
    }
    try std.testing.expectEqual(SYNC_WORD, testBitsToU32(bits.items, pre_start + PREAMBLE_BYTES * 8));

    // stop tone: last STOP_TONE_SECS * 19200 samples are 800 Hz
    const stop_start = samples.len - stop_samples;
    try std.testing.expect(testCorrelate(samples, stop_start, window, STOP_TONE_HZ) > 0.8 * corr_ref);
    try std.testing.expect(testCorrelate(samples, stop_start, window, GO_CUE_HZ) < 0.2 * corr_ref);
}

test "v2 data bitstream recovers the exact wire bytes" {
    const payload = "the quick brown fox jumps over the lazy dog 0123456789";
    const profile = LINK_PROFILES[1];
    const gz = try gzip(std.testing.allocator, payload);
    defer std.testing.allocator.free(gz);

    const wav = try encodeProfile(std.testing.allocator, payload, 1);
    defer std.testing.allocator.free(wav);
    const samples = try samplesOf(std.testing.allocator, wav);
    defer std.testing.allocator.free(samples);
    var bits = try testDemod(std.testing.allocator, samples, profile.samples_per_bit, profile.tone_low, profile.tone_high);
    defer bits.deinit(std.testing.allocator);

    const cue_samples: usize = @intFromFloat(GO_CUE_SECS * @as(f64, @floatFromInt(SAMPLE_RATE)));
    const stop_samples: usize = @intFromFloat(STOP_TONE_SECS * @as(f64, @floatFromInt(SAMPLE_RATE)));
    const cue_bits = cue_samples / profile.samples_per_bit;
    const stop_bits = stop_samples / profile.samples_per_bit;
    try std.testing.expectEqual(samples.len / profile.samples_per_bit, bits.items.len);

    const start = cue_bits + PREAMBLE_BYTES * 8 + 32;
    const wire_bits = bits.items.len - start - stop_bits;
    try std.testing.expect(wire_bits % 8 == 0);
    const wire_bytes = wire_bits / 8;
    const decoded = try std.testing.allocator.alloc(u8, wire_bytes);
    defer std.testing.allocator.free(decoded);
    testBitsToBytes(bits.items, start, decoded);

    // expected wire bytes, rebuilt from the same region the encoder fed in
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.append(std.testing.allocator, 1);
    try appendU32le(std.testing.allocator, &data, @intCast(gz.len));
    try data.appendSlice(std.testing.allocator, gz);
    try appendU32le(std.testing.allocator, &data, crc32IsoHdlc(data.items));
    const padded_len = ((data.items.len + PAD_GROUP - 1) / PAD_GROUP) * PAD_GROUP;
    const block_count = padded_len / RS_DATA_BLOCK;
    try std.testing.expectEqual(block_count * RS_BLOCK, wire_bytes);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    var blocks: [INTERLEAVE_DEPTH][RS_BLOCK]u8 = undefined;
    var i: usize = 0;
    while (i < block_count) : (i += 1) {
        var block: [RS_DATA_BLOCK]u8 = .{0} ** RS_DATA_BLOCK;
        const off = i * RS_DATA_BLOCK;
        if (off < data.items.len) {
            const n = @min(RS_DATA_BLOCK, data.items.len - off);
            @memcpy(block[0..n], data.items[off .. off + n]);
        }
        blocks[i % INTERLEAVE_DEPTH] = rsEncode(&block);
        if (i % INTERLEAVE_DEPTH == INTERLEAVE_DEPTH - 1) {
            var group = try interleave16(std.testing.allocator, &blocks);
            defer group.deinit(std.testing.allocator);
            try expected.appendSlice(std.testing.allocator, group.items);
        }
    }
    try std.testing.expectEqualSlices(u8, expected.items, decoded);

    // deinterleave the demodulated wire bytes back into codewords and recover
    // the data region (RS is systematic: message = first 223 bytes of each
    // codeword, so no decoder is needed to verify the region on the zig side)
    const region = try std.testing.allocator.alloc(u8, block_count * RS_DATA_BLOCK);
    defer std.testing.allocator.free(region);
    var k: usize = 0;
    while (k < block_count) : (k += 1) {
        for (0..RS_BLOCK) |bb| {
            const wb = decoded[bb * INTERLEAVE_DEPTH + k];
            if (bb < RS_DATA_BLOCK) region[k * RS_DATA_BLOCK + bb] = wb;
        }
    }
    try std.testing.expectEqualSlices(u8, data.items, region[0..data.items.len]);
    for (region[data.items.len..]) |pad_byte| try std.testing.expectEqual(@as(u8, 0), pad_byte);

    // the recovered region also validates end-to-end: profile byte, length,
    // crc, and gzip inflate back to the payload
    try std.testing.expectEqual(@as(u8, 1), region[0]);
    const rec_len = std.mem.readInt(u32, region[1..5][0..4], .little);
    try std.testing.expectEqual(@as(u32, @intCast(gz.len)), rec_len);
    const rec_crc = std.mem.readInt(u32, region[5 + rec_len ..][0..4], .little);
    try std.testing.expectEqual(crc32IsoHdlc(region[0 .. 5 + rec_len]), rec_crc);
    const back = try gunzip(std.testing.allocator, region[5 .. 5 + rec_len]);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualSlices(u8, payload, back);
}

test "v2 radio profile is slower than clean for the same payload" {
    const payload = "hello, world";
    const gz = try gzip(std.testing.allocator, payload);
    defer std.testing.allocator.free(gz);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.append(std.testing.allocator, 0);
    try appendU32le(std.testing.allocator, &data, @intCast(gz.len));
    try data.appendSlice(std.testing.allocator, gz);
    try appendU32le(std.testing.allocator, &data, crc32IsoHdlc(data.items));
    const padded_len = ((data.items.len + PAD_GROUP - 1) / PAD_GROUP) * PAD_GROUP;
    const wire_bytes = (padded_len / RS_DATA_BLOCK) * RS_BLOCK;

    const cue_samples: usize = @intFromFloat(GO_CUE_SECS * @as(f64, @floatFromInt(SAMPLE_RATE)));
    const stop_samples: usize = @intFromFloat(STOP_TONE_SECS * @as(f64, @floatFromInt(SAMPLE_RATE)));
    const fixed_bits = PREAMBLE_BYTES * 8 + 32;
    const clean_samples = cue_samples + stop_samples + (fixed_bits + wire_bytes * 8) * LINK_PROFILES[0].samples_per_bit;
    const radio_samples = cue_samples + stop_samples + (fixed_bits + wire_bytes * 8) * LINK_PROFILES[1].samples_per_bit;

    const clean_wav = try encodeProfile(std.testing.allocator, payload, 0);
    defer std.testing.allocator.free(clean_wav);
    const radio_wav = try encodeProfile(std.testing.allocator, payload, 1);
    defer std.testing.allocator.free(radio_wav);

    try std.testing.expectEqual(44 + clean_samples * 2, clean_wav.len);
    try std.testing.expectEqual(44 + radio_samples * 2, radio_wav.len);
    try std.testing.expect(radio_wav.len > clean_wav.len);
}

test "v2 encoder rejects unknown profile index" {
    try std.testing.expectError(error.BadProfile, encodeProfile(std.testing.allocator, "x", LINK_PROFILES.len));
}

test "v1 encode still emits a v1 frame" {
    const payload = "hi";
    const wav = try encode(std.testing.allocator, payload);
    defer std.testing.allocator.free(wav);
    const expected_samples = (PREAMBLE_LEN + 4 + payload.len + 4) * 8 * SAMPLES_PER_BIT;
    try std.testing.expectEqual(expected_samples * 2, wav.len - 44);

    const samples = try samplesOf(std.testing.allocator, wav);
    defer std.testing.allocator.free(samples);
    var bits = try testDemod(std.testing.allocator, samples, SAMPLES_PER_BIT, MARK_HZ, SPACE_HZ);
    defer bits.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected_samples / SAMPLES_PER_BIT, bits.items.len);
    const bytes = try std.testing.allocator.alloc(u8, bits.items.len / 8);
    defer std.testing.allocator.free(bytes);
    testBitsToBytes(bits.items, 0, bytes);

    for (0..PREAMBLE_LEN) |i| try std.testing.expectEqual(@as(u8, 0xAA), bytes[i]);
    const len = std.mem.readInt(u32, bytes[PREAMBLE_LEN..][0..4], .little);
    try std.testing.expectEqual(@as(u32, payload.len), len);
    try std.testing.expectEqualSlices(u8, payload, bytes[PREAMBLE_LEN + 4 .. PREAMBLE_LEN + 4 + payload.len]);
    const crc = std.mem.readInt(u32, bytes[PREAMBLE_LEN + 4 + payload.len ..][0..4], .little);
    try std.testing.expectEqual(crc32IsoHdlc(payload), crc);
}
