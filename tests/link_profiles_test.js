"use strict";
// Link profile + frame-v2 encoder tests. Two anchors, pinned against each
// other from opposite sides: this file reads tests/link_profiles.json and
// compares it to pinned literals (the zig side pins the SAME literals and
// compares the JSON against the LINK_PROFILES table in audio.zig). Then the
// zig v2 encoder (wavprobe) is driven end-to-end through the node decodeFrame
// (self-contained sync search, preamble gate, RS+deinterleave, crc) and must
// recover the payload byte-for-byte.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { decodeFrame, gunzipSync } = require("../src/decoder.js");

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
  const got = decodeFrame(wav);
  check(`decodeFrame selects profile (${run.profileName}, ${run.payload.name})`, got.profile === run.profileName);
  const back = gunzipSync(got.compressed);
  check(`payload round-trip (${run.profileName}, ${run.payload.name})`, bytesEqual(back, run.payload.data));
}

// 3. wavprobe CLI errors
try {
  execFileSync(wavprobe, ["nope"], { input: Buffer.alloc(0), stdio: "pipe" });
  check("wavprobe rejects unknown profile", false);
} catch (e) {
  check("wavprobe rejects unknown profile", e.status === 1 && String(e.stderr).includes("unknown profile"));
}

console.log(failures ? `\n${failures} FAILURE(S)` : "\nLINK PROFILE TESTS GREEN");
process.exitCode = failures ? 1 : 0;
