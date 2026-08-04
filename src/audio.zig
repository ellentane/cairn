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
