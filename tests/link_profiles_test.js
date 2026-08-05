"use strict";
// Link profile + frame-v2 encoder tests. Two anchors, pinned against each
// other from opposite sides: this file reads tests/link_profiles.json and
// compares it to pinned literals (the zig side pins the SAME literals and
// compares the JSON against the LINK_PROFILES table in audio.zig). Then the
// zig v2 encoder (wavprobe) is driven end-to-end through the existing node
// decoder primitives (demodIQ -> deinterleave -> rsDecode -> gunzipSync) and
// must recover the payload byte-for-byte.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { crc32, demodIQ, gunzipSync, rs } = require("../src/decoder.js");

let failures = 0;
function check(name, cond) {
  if (cond) console.log("PASS " + name);
  else { failures++; console.error("FAIL " + name); }
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

const root = path.join(__dirname, "..");
const j = JSON.parse(fs.readFileSync(path.join(__dirname, "link_profiles.json"), "utf8"));

// 1. JSON vs pinned literals (JS mirror of audio.zig's constants)
const PINNED = {
  sync_word: 0xD3A94E57, // = 3551088215
  preamble_bytes: 96,
  go_cue_hz: 400,
  go_cue_secs: 1.5,
  stop_tone_hz: 800,
  stop_tone_secs: 0.5,
  sample_rate: 19200,
  rs_data_block: 223,
  rs_block: 255,
  interleave_depth: 16,
};
const PROFILES = [
  { name: "clean", tone_low: 1200, tone_high: 2400, samples_per_bit: 8 },
  { name: "radio", tone_low: 1200, tone_high: 2000, samples_per_bit: 12 },
];

check("sync word 0xD3A94E57 === 3551088215", PINNED.sync_word === 3551088215);
for (const [k, v] of Object.entries(PINNED)) {
  check(`json ${k} matches pinned literal`, j[k] === v);
}
check("json profile count", j.profiles.length === PROFILES.length);
for (let i = 0; i < PROFILES.length; i++) {
  for (const k of Object.keys(PROFILES[i])) {
    check(`json profiles[${i}].${k} matches pinned literal`, j.profiles[i][k] === PROFILES[i][k]);
  }
}

// 2. frame-v2 end-to-end: zig encodeProfile -> node decoder primitives
execFileSync("zig", ["build", "wavprobe"], { stdio: "pipe" });
const wavprobe = path.join(root, "zig-out/bin/wavprobe");

function encodeV2(payload, profileName) {
  return execFileSync(wavprobe, [profileName], { input: Buffer.from(payload), maxBuffer: 64 * 1024 * 1024 });
}

function xorshift32(seed, len) {
  let s = seed >>> 0;
  const b = Buffer.alloc(len);
  for (let i = 0; i < len; i++) {
    s ^= (s << 13) >>> 0; s >>>= 0;
    s ^= s >>> 17;
    s ^= (s << 5) >>> 0; s >>>= 0;
    b[i] = s & 0xff;
  }
  return b;
}

function bitsToBytes(bits) {
  const out = new Uint8Array(Math.floor(bits.length / 8));
  for (let i = 0; i < out.length; i++) {
    let b = 0;
    for (let k = 0; k < 8; k++) b = (b << 1) | bits[i * 8 + k];
    out[i] = b;
  }
  return out;
}

function bitsToU32(bits, start) {
  let v = 0;
  for (let i = 0; i < 32; i++) v = (v << 1) | bits[start + i];
  return v >>> 0;
}

// wav -> samples -> bits -> wire bytes -> codewords -> data region -> payload
function decodeV2(wavBytes, profile) {
  if (String.fromCharCode(...wavBytes.subarray(0, 4)) !== "RIFF") throw new Error("not RIFF");
  const view = new DataView(wavBytes.buffer, wavBytes.byteOffset, wavBytes.byteLength);
  let off = 12, dataOff = -1, dataLen = 0;
  while (off + 8 <= wavBytes.length) {
    const id = String.fromCharCode(wavBytes[off], wavBytes[off + 1], wavBytes[off + 2], wavBytes[off + 3]);
    const len = view.getUint32(off + 4, true);
    if (id === "data") { dataOff = off + 8; dataLen = len; break; }
    off += 8 + len;
  }
  if (dataOff < 0) throw new Error("no data chunk");
  const samples = new Int16Array(wavBytes.buffer, wavBytes.byteOffset + dataOff, Math.floor(dataLen / 2));

  const sr = j.sample_rate;
  const spb = profile.samples_per_bit;
  const bits = demodIQ(samples, { sr, spb, tones: [profile.tone_low, profile.tone_high] });
  const cueBits = Math.round(j.go_cue_secs * sr / spb);
  const stopBits = Math.round(j.stop_tone_secs * sr / spb);
  const dataStart = cueBits + j.preamble_bytes * 8 + 32;
  if (bits.length !== samples.length / spb) throw new Error("bit count mismatch");
  return { bits, samples, dataStart, stopBits };
}

// parse the data region: [profile u8][len u32le][gzip][crc u32le], zero-padded
// to 223-byte blocks, RS-coded, depth-16 interleaved
function recoverRegion(wavBytes, profile) {
  const { bits, dataStart, stopBits } = decodeV2(wavBytes, profile);
  const wireBytes = bitsToBytes(bits.slice(dataStart, bits.length - stopBits));
  const groupLen = j.interleave_depth * j.rs_block;
  if (wireBytes.length % groupLen !== 0) throw new Error("wire length not a multiple of groupLen");
  const region = [];
  const cws = [];
  for (let g = 0; g < wireBytes.length; g += groupLen) {
    const group = rs.deinterleave(wireBytes.subarray(g, g + groupLen), j.interleave_depth, j.rs_block);
    if (group.length !== j.interleave_depth) throw new Error("bad group size");
    for (const cw of group) {
      const dec = rs.decode(cw);
      if (dec === null) throw new Error("uncorrectable codeword");
      if (!bytesEqual(rs.encode(dec), cw)) throw new Error("codeword re-encode mismatch");
      cws.push(cw);
      for (const b of dec) region.push(b);
    }
  }
  return { region: new Uint8Array(region), cws };
}

// frame envelope: preamble byte 0xAA at the cue boundary, sync word right
// after the preamble, stop tone at the tail
function checkFrameEnvelope(wavBytes, profile) {
  const { bits, dataStart } = decodeV2(wavBytes, profile);
  const cueBits = dataStart - j.preamble_bytes * 8 - 32;
  let pre = 0;
  for (let i = 0; i < 8; i++) pre = (pre << 1) | bits[cueBits + i];
  const sync = bitsToU32(bits, dataStart - 32);
  return { preambleByte: pre, sync, bits };
}

const payloads = [
  { name: "small", data: Buffer.from("hello cairn v2") },
  { name: "40 KB pseudo-random", data: xorshift32(0x9E3779B9, 40 * 1024) },
  { name: "32 KB repetitive", data: Buffer.alloc(32 * 1024, 0x61) },
];
const runs = [
  { payload: payloads[0], profileName: "clean", index: 0 },
  { payload: payloads[0], profileName: "radio", index: 1 },
  { payload: payloads[1], profileName: "radio", index: 1 },
  { payload: payloads[2], profileName: "radio", index: 1 },
];
for (const run of runs) {
  const wav = encodeV2(run.payload.data, run.profileName);
  const profile = PROFILES[run.index];
  check(`wav is RIFF (${run.profileName}, ${run.payload.name})`,
    String.fromCharCode(...wav.subarray(0, 4)) === "RIFF" &&
    String.fromCharCode(...wav.subarray(8, 12)) === "WAVE");

  const env = checkFrameEnvelope(wav, profile);
  check(`preamble first byte 0xAA (${run.profileName}, ${run.payload.name})`, env.preambleByte === 0xAA);
  check(`sync word at bit offset (${run.profileName}, ${run.payload.name})`, env.sync === j.sync_word);

  const { region, cws } = recoverRegion(wav, profile);
  check(`profile byte (${run.profileName}, ${run.payload.name})`, region[0] === run.index);
  const len = ((region[1] | (region[2] << 8) | (region[3] << 16) | (region[4] << 24)) >>> 0);
  check(`compressed length field (${run.profileName}, ${run.payload.name})`, len > 0 && 5 + len + 4 <= region.length);
  const gotCrc = ((region[5 + len] | (region[6 + len] << 8) | (region[7 + len] << 16) | (region[8 + len] << 24)) >>> 0);
  check(`crc over data region (${run.profileName}, ${run.payload.name})`, crc32(region.subarray(0, 5 + len)) === gotCrc);
  let tailZeros = true;
  for (let i = 9 + len; i < region.length; i++) if (region[i] !== 0) { tailZeros = false; break; }
  check(`region tail zero-padding (${run.profileName}, ${run.payload.name})`, tailZeros);
  const back = gunzipSync(region.subarray(5, 5 + len));
  check(`payload round-trip (${run.profileName}, ${run.payload.name})`, bytesEqual(back, run.payload.data));
  check(`codeword count is a multiple of depth (${run.profileName}, ${run.payload.name})`, cws.length % j.interleave_depth === 0);
}

// multi-group wire stays row-major across groups: the 40 KB run spans 12
// groups, so the checks above already covered group boundaries

// 3. wavprobe CLI errors
try {
  execFileSync(wavprobe, ["nope"], { input: Buffer.alloc(0), stdio: "pipe" });
  check("wavprobe rejects unknown profile", false);
} catch (e) {
  check("wavprobe rejects unknown profile", e.status === 1 && String(e.stderr).includes("unknown profile"));
}

console.log(failures ? `\n${failures} FAILURE(S)` : "\nLINK PROFILE TESTS GREEN");
process.exitCode = failures ? 1 : 0;
