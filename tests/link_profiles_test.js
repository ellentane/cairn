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
  { name: "radio", tone_low: 1200, tone_high: 2300, samples_per_bit: 14 },
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

// rebuild a wav around resampled (or sliced) samples, keeping the v2 header
function rebuildWav(samples, sr) {
  sr = sr || 19200;
  const hdr = Buffer.alloc(44);
  hdr.write("RIFF", 0); hdr.writeUInt32LE(36 + samples.length * 2, 4); hdr.write("WAVE", 8);
  hdr.write("fmt ", 12); hdr.writeUInt32LE(16, 16); hdr.writeUInt16LE(1, 20); hdr.writeUInt16LE(1, 22);
  hdr.writeUInt32LE(sr, 24); hdr.writeUInt32LE(sr * 2, 28); hdr.writeUInt16LE(2, 32); hdr.writeUInt16LE(16, 34);
  hdr.write("data", 36); hdr.writeUInt32LE(samples.length * 2, 40);
  const out = Buffer.alloc(44 + samples.length * 2);
  hdr.copy(out, 0);
  for (let i = 0; i < samples.length; i++) out.writeInt16LE(samples[i], 44 + i * 2);
  return out;
}

function samplesOf(wav) {
  const out = new Int16Array((wav.length - 44) / 2);
  for (let i = 0; i < out.length; i++) out[i] = wav.readInt16LE(44 + i * 2);
  return out;
}

// linear resample by `factor` (>1 = longer): simulates a recorder clock offset
function resample(samples, factor) {
  const out = new Int16Array(Math.floor(samples.length * factor));
  for (let i = 0; i < out.length; i++) {
    const p = i / factor;
    const i0 = Math.floor(p), f = p - i0;
    const v0 = samples[Math.min(i0, samples.length - 1)];
    const v1 = samples[Math.min(i0 + 1, samples.length - 1)];
    out[i] = Math.round(v0 + (v1 - v0) * f);
  }
  return out;
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

// 3. robustness battery: normalization, drift tracking, rescan, stats
{
  const run = runs[2]; // 40 KB pseudo-random, radio profile
  const wav = encodeV2(run.payload.data, run.profileName);

  // 3a. stats are populated and sane
  const ok = decodeFrame(wav);
  check("stats: syncSnr positive", ok.stats && ok.stats.syncSnr > 0);
  check("stats: rsCorrections non-empty and >= 0", Array.isArray(ok.stats.rsCorrections) &&
    ok.stats.rsCorrections.length > 0 && ok.stats.rsCorrections.every((n) => n >= 0));

  // 3b. RS overload: 17 errors in ONE codeword (> t=16) must fail loudly.
  // The test first demodulates the actual region bytes so it can flip them to
  // their complements — guaranteed errors regardless of payload content.
  // Interleaving maps 17 consecutive region bytes of one codeword to 17 wire
  // bytes at stride 16, so every one lands in the same codeword.
  const overloadWav = Buffer.from(wav);
  const SR = 19200, spb = 14; // radio profile encoder constants
  const dataStart = SR * 1.5 + 96 * 8 * spb + 32 * spb; // go cue + preamble + sync
  function demodRegionBytes(buf, nBytes) {
    const bytes = [];
    for (let r = 0; r < nBytes; r++) {
      let byte = 0;
      for (let bit = 0; bit < 8; bit++) {
        const t0 = dataStart + (r * 8 + bit) * spb;
        let mI = 0, mQ = 0, sI = 0, sQ = 0;
        for (let s = 0; s < spb; s++) {
          const tt = t0 + s, v = buf.readInt16LE(44 + tt * 2);
          mI += v * Math.cos(2 * Math.PI * 1200 * tt / SR); mQ += v * Math.sin(2 * Math.PI * 1200 * tt / SR);
          sI += v * Math.cos(2 * Math.PI * 2300 * tt / SR); sQ += v * Math.sin(2 * Math.PI * 2300 * tt / SR);
        }
        byte = (byte << 1) | (Math.hypot(mI, mQ) >= Math.hypot(sI, sQ) ? 1 : 0);
      }
      bytes.push(byte);
    }
    return bytes;
  }
  const orig = demodRegionBytes(overloadWav, 232);
  for (let i = 0; i < 17; i++) {
    const r = 200 + i;
    const want = orig[r] ^ 0xFF; // complement: guaranteed different
    // region byte r -> block j = r/223, byte b = r mod 223, codeword k = j mod 16,
    // group g = j/16; wire position (in group) = b*16 + k -> signal sample
    // dataStart + (g*48960 + b*16 + k) * 8 * spb
    const j = Math.floor(r / 223), b = r % 223, k = j % 16, g = Math.floor(j / 16);
    const base = dataStart + (g * 48960 + b * 16 + k) * 8 * spb;
    for (let bit = 0; bit < 8; bit++) {
      const bitVal = (want >> (7 - bit)) & 1;
      const toneHz = bitVal === 1 ? 1200 : 2300;
      const sample = base + bit * spb;
      for (let s = 0; s < spb; s++) {
        overloadWav.writeInt16LE(Math.round(12000 * Math.sin(2 * Math.PI * toneHz * s / SR)), 44 + (sample + s) * 2);
      }
    }
  }
  let threw = null;
  try { decodeFrame(overloadWav); } catch (e) { threw = e; }
  check("RS overload (17 errors in one codeword) -> RSCorrectionFailed", threw && threw.name === "RSCorrectionFailed");

  // 3c. truncated frame: cut the data chunk to 85% -> clean error, never
  // wrong output (the final partial group fails RS or the CRC never matches)
  const truncWav = Buffer.from(wav);
  const cut = Math.floor(((truncWav.length - 44) / 2) * 0.85);
  truncWav.writeUInt32LE(cut * 2, 40); // shrink the data chunk length
  truncWav.writeUInt32LE(36 + cut * 2, 4);
  const truncBuf = Buffer.from(truncWav.subarray(0, 44 + cut * 2));
  threw = null;
  try { decodeFrame(truncBuf); } catch (e) { threw = e; }
  check("truncated frame -> clean error", threw !== null && (threw.name === "RSCorrectionFailed" || threw.name === "CRCError" || threw.name === "SyncNotFound"));

  // 3d. RS burst injection at wav level: 100 consecutive PCM samples flipped
  // mid-payload (60% through the frame = safely inside the data region) -> the
  // interleave+RS must reconstruct the exact original payload
  const burstWav = Buffer.from(wav);
  const mid = Math.floor(((burstWav.length - 44) / 2) * 0.6);
  for (let i = 0; i < 100; i++) {
    const off = 44 + (mid + i) * 2;
    burstWav.writeInt16LE(burstWav.readInt16LE(off) ^ 0x5A5A, off);
  }
  const burstGot = decodeFrame(burstWav);
  check("RS burst injection -> exact payload", bytesEqual(gunzipSync(burstGot.compressed), run.payload.data));

  // 3e. drift: 100 ppm recorder clock (linear resample by 1.0001) -> the
  // early-late tracker must hold phase over the ~2-minute frame
  const driftWav = rebuildWav(resample(samplesOf(wav), 1.0001));
  const driftGot = decodeFrame(driftWav);
  check("100 ppm drift -> exact payload", bytesEqual(gunzipSync(driftGot.compressed), run.payload.data));

  // 3f. preamble clipped: drop the first 100 samples of the frame (into the
  // go cue) — sync search must still find the frame
  const s = samplesOf(wav);
  const clipWav = rebuildWav(s.slice(100));
  const clipGot = decodeFrame(clipWav);
  check("preamble partially clipped -> decodes", bytesEqual(gunzipSync(clipGot.compressed), run.payload.data));

  // 3g. corrupted preamble: flip 20 random bytes in the preamble region
  const pWav = Buffer.from(wav);
  let x = 0x1234ABCD;
  for (let i = 0; i < 20; i++) {
    x = (Math.imul(x, 1664525) + 1013904223) >>> 0;
    const byteOff = 44 + (SR * 1.5) * 2 + ((x % (96 * 8 * spb)) >> 3) * 2;
    pWav[byteOff] ^= 0xFF;
  }
  const pGot = decodeFrame(pWav);
  check("corrupted preamble bytes -> decodes", bytesEqual(gunzipSync(pGot.compressed), run.payload.data));
}

// 4. fmt-aware decoding (Task 5): sample rate, channels, bit depth, containers
{
  const run = runs[2]; // 40 KB pseudo-random, radio profile
  const wav = encodeV2(run.payload.data, run.profileName);
  const mono = samplesOf(wav);

  // 4a/4b. recorder sample rates: linear resample keeps the physical tone
  // frequencies; spb becomes fractional (44.1k: 27.5625) or integral (48k: 30.0)
  for (const sr of [44100, 48000]) {
    const rt = rebuildWav(resample(mono, sr / 19200), sr);
    const got = decodeFrame(rt);
    check(`${sr} Hz wav -> exact payload`, bytesEqual(gunzipSync(got.compressed), run.payload.data));
  }

  // 4a-extra. 44.1 kHz + 100 ppm recorder drift: fractional spb and the
  // re-anchoring tracker together
  {
    const rt = rebuildWav(resample(mono, (44100 / 19200) * 1.0001), 44100);
    const got = decodeFrame(rt);
    check("44.1 kHz wav + 100 ppm drift -> exact payload", bytesEqual(gunzipSync(got.compressed), run.payload.data));
  }

  // 4c. stereo wav: channel 0 carries the frame, channel 1 is uncorrelated
  // noise -> demux must recover channel 0 exactly
  let nx = 0x12345678;
  const noise = new Int16Array(mono.length);
  for (let i = 0; i < noise.length; i++) {
    nx ^= (nx << 13) >>> 0; nx ^= nx >>> 17; nx ^= (nx << 5) >>> 0; nx >>>= 0;
    noise[i] = nx & 0xFFFF;
  }
  const stBuf = Buffer.alloc(44 + mono.length * 4);
  stBuf.write("RIFF", 0); stBuf.writeUInt32LE(36 + mono.length * 4, 4); stBuf.write("WAVE", 8);
  stBuf.write("fmt ", 12); stBuf.writeUInt32LE(16, 16); stBuf.writeUInt16LE(1, 20); stBuf.writeUInt16LE(2, 22);
  stBuf.writeUInt32LE(19200, 24); stBuf.writeUInt32LE(19200 * 4, 28); stBuf.writeUInt16LE(4, 32); stBuf.writeUInt16LE(16, 34);
  stBuf.write("data", 36); stBuf.writeUInt32LE(mono.length * 4, 40);
  for (let i = 0; i < mono.length; i++) {
    stBuf.writeInt16LE(mono[i], 44 + i * 4);
    stBuf.writeInt16LE(noise[i], 44 + i * 4 + 2);
  }
  const stereoGot = decodeFrame(stBuf);
  check("stereo wav (ch0 frame, ch1 noise) -> exact payload", bytesEqual(gunzipSync(stereoGot.compressed), run.payload.data));

  // 4d. 8-bit PCM (unsigned): parseWav converts to 16-bit signed
  const u8Buf = Buffer.alloc(44 + mono.length);
  u8Buf.write("RIFF", 0); u8Buf.writeUInt32LE(36 + mono.length, 4); u8Buf.write("WAVE", 8);
  u8Buf.write("fmt ", 12); u8Buf.writeUInt32LE(16, 16); u8Buf.writeUInt16LE(1, 20); u8Buf.writeUInt16LE(1, 22);
  u8Buf.writeUInt32LE(19200, 24); u8Buf.writeUInt32LE(19200, 28); u8Buf.writeUInt16LE(1, 32); u8Buf.writeUInt16LE(8, 34);
  u8Buf.write("data", 36); u8Buf.writeUInt32LE(mono.length, 40);
  for (let i = 0; i < mono.length; i++) u8Buf.writeUInt8((mono[i] >> 8) + 128, 44 + i);
  let u8Got = null;
  try { u8Got = decodeFrame(u8Buf); } catch (e) { u8Got = e; }
  check("8-bit PCM wav -> exact payload", u8Got !== null && u8Got.profile !== undefined &&
    bytesEqual(gunzipSync(u8Got.compressed), run.payload.data));

  // 4e. float wav (format tag 3): classified error, never garbage. Decision:
  // reject rather than convert — phone memo apps record PCM, and the browser
  // path (Task 8) transcodes everything else via decodeAudioData
  const flBuf = Buffer.alloc(44 + mono.length * 4);
  flBuf.write("RIFF", 0); flBuf.writeUInt32LE(36 + mono.length * 4, 4); flBuf.write("WAVE", 8);
  flBuf.write("fmt ", 12); flBuf.writeUInt32LE(16, 16); flBuf.writeUInt16LE(3, 20); flBuf.writeUInt16LE(1, 22);
  flBuf.writeUInt32LE(19200, 24); flBuf.writeUInt32LE(19200 * 4, 28); flBuf.writeUInt16LE(4, 32); flBuf.writeUInt16LE(32, 34);
  flBuf.write("data", 36); flBuf.writeUInt32LE(mono.length * 4, 40);
  for (let i = 0; i < mono.length; i++) flBuf.writeFloatLE(mono[i] / 32768, 44 + i * 4);
  let threw = null;
  try { decodeFrame(flBuf); } catch (e) { threw = e; }
  check("float wav -> classified UnsupportedFormat error", threw !== null && threw.name === "UnsupportedFormat");

  // 4f. non-RIFF container (m4a/mp3 style): classified WavParseError
  threw = null;
  try { decodeFrame(Buffer.from([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])); } catch (e) { threw = e; }
  check("m4a/mp3 container -> classified WavParseError", threw !== null && threw.name === "WavParseError");

  // 4g. go cue replaced with silence: sync search must not depend on it
  const noCue = samplesOf(wav);
  noCue.fill(0, 0, 28800);
  const noCueGot = decodeFrame(rebuildWav(noCue));
  check("go cue replaced with silence -> exact payload", bytesEqual(gunzipSync(noCueGot.compressed), run.payload.data));
}

// 5a. sync search tolerance (Task 6b-1): the sync word may arrive with up to
// 8 bit errors (echo reflections and clock-offset phase shifts land inside
// the sync window); the decoder must accept matches within the tolerance but
// keep rejecting worse ones. Bits are flipped by writing the OPPOSITE tone
// into the bit's sample window, so the demodulated bit provably flips
// regardless of content.
{
  const SR = 19200, spb = 14; // radio profile encoder constants
  const SYNC_WORD = 0xD3A94E57;
  const syncStart = SR * 1.5 + 96 * 8 * spb; // go cue + preamble
  const wav = encodeV2(payloads[0].data, "radio"); // small payload, fast decode

  function flipSyncBits(buf, bits) {
    const out = Buffer.from(buf);
    for (const b of bits) {
      const bitVal = (SYNC_WORD >> (31 - b)) & 1;
      const toneHz = bitVal === 1 ? 2300 : 1200; // opposite of the transmitted tone
      const sample = syncStart + b * spb;
      for (let s = 0; s < spb; s++) {
        out.writeInt16LE(Math.round(12000 * Math.sin(2 * Math.PI * toneHz * s / SR)), 44 + (sample + s) * 2);
      }
    }
    return out;
  }

  for (const [name, bits] of [["1 bit error", [3]], ["2 bit errors", [3, 17]], ["3 bit errors", [3, 17, 25]]]) {
    let got = null;
    try { got = decodeFrame(flipSyncBits(wav, bits)); } catch (e) { got = e; }
    check(`sync word with ${name} -> decodes`, got !== null && got.profile !== undefined &&
      bytesEqual(gunzipSync(got.compressed), payloads[0].data));
  }
  let threw = null;
  try { decodeFrame(flipSyncBits(wav, [3, 7, 11, 15, 19, 23, 27, 30, 1, 5])); } catch (e) { threw = e; }
  check("sync word with 10 bit errors -> SyncNotFound", threw !== null && threw.name === "SyncNotFound");
}

// 6. wavprobe CLI errors
try {
  execFileSync(wavprobe, ["nope"], { input: Buffer.alloc(0), stdio: "pipe" });
  check("wavprobe rejects unknown profile", false);
} catch (e) {
  check("wavprobe rejects unknown profile", e.status === 1 && String(e.stderr).includes("unknown profile"));
}

console.log(failures ? `\n${failures} FAILURE(S)` : "\nLINK PROFILE TESTS GREEN");
process.exitCode = failures ? 1 : 0;
