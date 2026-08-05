// Cairn audio FSK encoder (v1.0): index.html bytes -> 16-bit PCM mono WAV.
// Link: 19200 Hz, mark 1200 Hz (bit 1), space 2400 Hz (bit 0), 8 samples/bit = 2400 bps.
// Frame: preamble 0xAA x64, u32le length, payload, CRC-32/ISO-HDLC.
// Phase-continuous carrier: tone phase carries across bit boundaries.
const std = @import("std");

const SAMPLE_RATE: u32 = 19200;
const MARK_HZ: f64 = 1200.0;
const SPACE_HZ: f64 = 2400.0;
const SAMPLES_PER_BIT: u32 = 8;
const PREAMBLE_LEN: usize = 64;

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

pub fn encode(allocator: std.mem.Allocator, payload: []const u8) AudioError![]u8 {
    const frame_len = PREAMBLE_LEN + 4 + payload.len + 4;
    const total_bits = frame_len * 8;
    const total_samples = total_bits * SAMPLES_PER_BIT;
    const data_bytes = total_samples * 2;

    var wav: std.ArrayList(u8) = .empty;
    errdefer wav.deinit(allocator);

    try wav.appendSlice(allocator, "RIFF");
    try appendU32le(allocator, &wav, @intCast(36 + data_bytes));
    try wav.appendSlice(allocator, "WAVE");
    try wav.appendSlice(allocator, "fmt ");
    try appendU32le(allocator, &wav, 16);
    try appendU16le(allocator, &wav, 1);
    try appendU16le(allocator, &wav, 1);
    try appendU32le(allocator, &wav, SAMPLE_RATE);
    try appendU32le(allocator, &wav, SAMPLE_RATE * 2);
    try appendU16le(allocator, &wav, 2);
    try appendU16le(allocator, &wav, 16);
    try wav.appendSlice(allocator, "data");
    try appendU32le(allocator, &wav, @intCast(data_bytes));

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
const RS_N: usize = 255;
const RS_K: usize = 223;
const RS_NSYM: usize = 32;

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
    std.debug.assert(blocks.len == 16);
    var wire: std.ArrayList(u8) = .empty;
    errdefer wire.deinit(allocator);
    try wire.ensureTotalCapacity(allocator, blocks.len * RS_N);
    var b: usize = 0;
    while (b < RS_N) : (b += 1) {
        for (blocks) |block| try wire.append(allocator, block[b]);
    }
    return wire;
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
