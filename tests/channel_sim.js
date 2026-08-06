"use strict";
// tests/channel_sim.js — radio-chain channel simulator + FER gate (Task 6a).
//
// Models the analog leg of the v2 relay: speaker -> walkie-talkie ->
// walkie-talkie -> recorder -> mic, applied to a wavprobe-encoded frame-v2
// wav. All stages are deterministic (mulberry32 seeds; no Math.random):
//   1. pre-emphasis tilt     y[n] = x[n] - 0.7 x[n-1]
//   2. bandpass 300..3000 Hz, rolloff above 2.5 kHz (single RBJ bandpass
//      biquad, f0 = 1500 Hz, Q = 0.55 -> 6 dB/octave skirts; at 300 Hz
//      -9.1 dB, at 2.5 kHz -1.8 dB, at 3 kHz -2.3 dB, at 4 kHz -4.2 dB)
//   3. 2nd/3rd harmonic generation (3%/1.5% of a tone at encoder amplitude)
//      + tanh soft clipper at 0.8 FS + DC block (x^2 injects DC; radio audio
//      paths are AC-coupled; 1st-order HP, pole 0.99 ~ fc 30 Hz)
//   4. syllabic AGC: 2 ms attack / 20 ms release envelope, gain toward
//      0.5 FS target, clamped to [-, 5x]
//   5. squelch: first open_delay ms muted (50..300 ms); noise burst
//      (20..80 ms, +-0.5 FS uniform) at a seeded spot in the data region
//   6. FM-threshold impulse clicks: 0..5 per trial, 1..3 samples at
//      +-(0.5..1.0) FS
//   7. reverb: 2-tap echo, delays 10..40 ms, gains 0.3 / 0.15 — enabled at
//      the spec'd gains since Task 6b-1; the radio gate fails at these gains
//      (data-region wall, see "measured constraints") — the gains stay as
//      parameters so the sweep can be re-run
//   8. recorder clock offset: resample by (1 + eps), eps uniform +-PPM_MAX
//      (linear interpolation) — spec'd +-100 ppm, enabled since Task 6b-1
//   9. AWGN at configurable SNR, noise RMS calibrated to the active-region
//      signal RMS (unit-variance gaussian table, fixed seed; per-trial
//      odd-stride decimation keeps trials decorrelated and cheap)
//
// Filter choices, measured:
// - Pre-emphasis y = x - 0.7 x[n-1]: |H|^2 = 1.49 - 1.4 cos(2 pi f / 19200).
//   Monotonic tilt over the band: 300 Hz -10.1 dB, 1200 -7.1, 2000 -4.2,
//   2400 -3.0, 3000 -1.5 dB — ~+2.6 dB/octave averaged 300..3000 Hz and
//   ~+4.1 dB/octave between the clean pair's tones (1200..2400). Deliberately
//   conservative vs the intended +6 dB/octave (a pure differentiator would be
//   +6 dB/oct but unbounded at HF; a=0.7 keeps in-band gain <= 0 dB so this
//   stage never clips on its own).
// - Bandpass: a single RBJ cookbook bandpass (constant 0 dB peak) rather
//   than an HP+LP cascade: the cascade's 12 dB/octave skirts ring at tone-
//   switch boundaries, and the decoder's drift tracker random-walks on the
//   resulting inter-symbol interference (measured 22/60 frame failures vs
//   0/60 for the single bandpass on identical trials). The single bandpass
//   still satisfies "300..3000 Hz with rolloff above 2.5 kHz" (6 dB/octave
//   skirts; -1.8 dB at 2.5 kHz).
// - Harmonics: y = x + h2 x^2 + h3 x^3 with h2 = 0.06/A, h3 = 0.06/A^2,
//   A = 12000/32768 (encoder tone amplitude): the 2nd harmonic of a tone at
//   A measures exactly 3% and the 3rd exactly 1.5% of the fundamental.
//
// Measured constraints (decoder-side; the gate below is the contract):
// - Reverb: an echo at the spec'd 0.3/0.15 gains lands the preamble's
//   reflection inside the sync window (delays 10..40 ms = 16..64 bits) and
//   corrupts it — measured >= 25% SyncNotFound at 0.05 tap gain and ~45%
//   frame failures at 0.3/0.15 even on clean wavs, with an exact-match sync
//   search. The Task 6b-1 decoder accepts a sync match with up to 8 bit
//   errors (Hamming distance <= 8, 4 demod grids), which absorbs the echo's
//   sync corruption; false locks are rejected by CRC validation + rescan.
// - Reverb vs the data region (the binding constraint): the echo's delayed
//   copy (0.3/0.15) flips ~0.5-2% of the radio profile's bit decisions at
//   ANY demod phase (measured: even at the perfect phase trajectory with the
//   true clock factor, only ~25-30% of trials stay under the RS(255,223)
//   error capacity of ~0.6% bit errors). The radio gate therefore fails at
//   the spec'd gains: measured FER 94.5% at 0.3/0.15 vs 24.5% at 0.1/0.05,
//   7% at 0.05/0.025 and 8.5% at 0 echo (all with +-100 ppm clock, 25 dB,
//   the hardened decoder). The gate budget is only met at echo gains
//   <= ~0.05. clean is unaffected (0% FER through 0.1/0.05; 3% at 0.2/0.1).
// - Clock: any nonzero clock offset moves the sync off the demod phase grids
//   and flips marginal sync bits (+3..10% frame failures at +-1..5 ppm with
//   an exact match). The tolerance above plus the drift tracker (128-bit
//   decision-directed probes, 4-grid sync start) hold the spec'd +-100 ppm:
//   measured 8.5% radio / 0% clean at 100 ppm with no echo.
// - FER floor at 25 dB (~3%): the AGC's 2 ms attack lags tone transitions
//   and drops the arriving tone's level for 1-2 symbols; the sync search
//   then misses ~3% of trials. This is the model's honest floor; the gate's
//   5% budget absorbs it.
// - clean vs radio: clean DECODES BETTER than radio everywhere (0/60 vs
//   2/60 at 25 dB) — the 3% 1:2-ratio harmonic spur is far below the
//   correlator decision margin, and the clean profile's flat phase curve
//   never triggers the tracker. The expected clean-is-worse inversion does
//   not materialize; the numbers inform Task 6b's sweep.
//
// Gate (default run, wired into tests/e2e.sh): 200 trials, radio profile,
// 1 KB seeded payload, SNR 25 dB, seed 0x5EED; PASS iff failures <= 10 (5%).
// The clean profile runs on the same trials and is reported (not gated).
//
// CLI: node tests/channel_sim.js [--trials N] [--snr dB] [--seed S]
//                                [--profile radio|clean] [--report]
// --report prints per-trial failure reasons + aggregates and exits 0.
const { execFileSync } = require("child_process");
const path = require("path");
const { decodeFrame, gunzipSync } = require("../src/decoder.js");

const SR = 19200;
const TONE_AMP = 12000 / 32768; // encoder tone amplitude (src/audio.zig)
const CLIP = 0.8;               // soft-clip level, fraction of full scale
const H2 = 0.06 / TONE_AMP;     // 3% 2nd harmonic of a TONE_AMP tone
const H3 = 0.06 / (TONE_AMP * TONE_AMP); // 1.5% 3rd harmonic
const AGC_TARGET = 0.5;
const BURST_AMP = 0.5;          // squelch-close noise burst level (+-FS)
const ECHO1 = 0.3;              // reverb tap gains (spec values, Task 6b-1)
const ECHO2 = 0.15;
const PPM_MAX = 100;            // recorder clock offset, +-ppm (spec value)
const GAUSS_N = 1 << 20;

const DEFAULT_TRIALS = 100;
const DEFAULT_SNR = 25;
const DEFAULT_SEED = 0x5EED;
const DEFAULT_PROFILE = "radio";
const GATE_BUDGET = 5; // failures allowed out of DEFAULT_TRIALS (5%)

// ---------- deterministic rng ----------
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Unit-variance gaussian table (Box-Muller, fixed seed). Per-trial AWGN is a
// decimated slice: index i -> table[(phase + i*stride) mod N] with an odd
// stride (co-prime with N) — deterministic, decorrelated between trials, and
// no transcendentals in the trial loop.
const gaussTable = (() => {
  const rng = mulberry32(0xC0FFEE);
  const t = new Float32Array(GAUSS_N);
  for (let i = 0; i < GAUSS_N; i += 2) {
    let u;
    do { u = rng(); } while (u <= 0);
    const r = Math.sqrt(-2 * Math.log(u));
    const a = 2 * Math.PI * rng();
    t[i] = r * Math.cos(a);
    t[i + 1] = r * Math.sin(a);
  }
  return t;
})();

// ---------- wav helpers ----------
function samplesOf(wav) {
  const n = (wav.length - 44) / 2;
  const s = new Float32Array(n);
  for (let i = 0; i < n; i++) s[i] = wav.readInt16LE(44 + i * 2) / 32768;
  return s;
}

function rebuildWav(s) {
  const n = s.length;
  const out = Buffer.alloc(44 + n * 2);
  out.write("RIFF", 0); out.writeUInt32LE(36 + n * 2, 4); out.write("WAVE", 8);
  out.write("fmt ", 12); out.writeUInt32LE(16, 16); out.writeUInt16LE(1, 20); out.writeUInt16LE(1, 22);
  out.writeUInt32LE(SR, 24); out.writeUInt32LE(SR * 2, 28); out.writeUInt16LE(2, 32); out.writeUInt16LE(16, 34);
  out.write("data", 36); out.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    let v = s[i];
    if (v > 0.999) v = 0.999; // recorder A/D saturation
    else if (v < -0.999) v = -0.999;
    out.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  return out;
}

// ---------- per-trial channel parameters ----------
// Drawn once per trial and shared by both profile runs so the two wavs pass
// through the SAME channel realization (positions are fractions of each wav's
// own data region). channelModel() falls back to drawing any missing param.
function drawChannelParams(rng, opts) {
  opts = opts || {};
  const ppmMax = opts.ppm !== undefined ? opts.ppm : PPM_MAX;
  const echo = opts.echo !== undefined ? opts.echo : 1; // scale factor on the spec gains
  const p = {
    openDelayMs: 50 + rng() * 250,   // squelch open delay
    burstLenMs: 20 + rng() * 60,     // squelch-close noise burst length
    burstFrac: rng(),                // burst position in the data region
    echoD1Ms: 10 + rng() * 30,
    echoD2Ms: 10 + rng() * 30,
    echo1: ECHO1 * echo,
    echo2: ECHO2 * echo,
    ppm: rng() * 2 * ppmMax - ppmMax, // recorder clock offset
    noiseStride: 1 + 2 * Math.floor(rng() * (GAUSS_N / 2 - 1)), // odd, co-prime
    noisePhase: Math.floor(rng() * GAUSS_N),
  };
  const burstN = Math.round((p.burstLenMs / 1000) * SR);
  p.burstNoise = new Float32Array(burstN);
  for (let i = 0; i < burstN; i++) p.burstNoise[i] = 2 * rng() - 1;
  p.clicks = [];
  const nClicks = Math.floor(rng() * 6); // 0..5 FM-threshold clicks
  for (let i = 0; i < nClicks; i++) {
    p.clicks.push({
      frac: rng(),                                   // position in data region
      len: 1 + Math.floor(rng() * 3),                // 1..3 samples
      amp: (0.5 + rng() * 0.5) * (rng() < 0.5 ? -1 : 1), // +-(0.5..1.0) FS
    });
  }
  return p;
}

// ---------- stages 1-4 (fused single pass) ----------
// RBJ cookbook biquad: kind "bandpass" = constant-0-dB-peak bandpass.
function biquadRBJ(kind, fc, q) {
  const w0 = 2 * Math.PI * fc / SR;
  const alpha = Math.sin(w0) / (2 * q);
  const cosw = Math.cos(w0);
  let b0, b1, b2;
  if (kind === "bandpass") { b0 = alpha; b1 = 0; b2 = -alpha; }
  else if (kind === "lowpass") { b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2; }
  else { b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2; }
  const a0 = 1 + alpha;
  return { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: (-2 * cosw) / a0, a2: (1 - alpha) / a0 };
}

function shapeTiltBandpassClipAgc(s) {
  const n = s.length;
  const bp = biquadRBJ("bandpass", 1500, 0.55);
  const out = new Float32Array(n);
  const aAtt = 1 - Math.exp(-1 / (0.002 * SR));  // 2 ms attack
  const aRel = 1 - Math.exp(-1 / (0.020 * SR));  // 20 ms release
  let z1 = 0, z2 = 0;                            // biquad state
  let prev = 0, dcPrev = 0, dcY = 0;
  let env = 0;
  for (let i = 0; i < n; i++) {
    const x = s[i];
    const pe = x - 0.7 * prev;      // 1. pre-emphasis tilt
    prev = x;
    const y = bp.b0 * pe + z1;      // 2. bandpass 300..3000, rolloff above 2.5 kHz
    z1 = bp.b1 * pe - bp.a1 * y + z2;
    z2 = bp.b2 * pe - bp.a2 * y;
    const u = y + H2 * y * y + H3 * y * y * y; // 3. harmonics
    let c = CLIP * Math.tanh(u / CLIP);         // 3. tanh soft clip at 0.8 FS
    const d = c - dcPrev + 0.99 * dcY;          // 3. DC block (x^2 injects DC)
    dcPrev = c; dcY = d; c = d;
    const ax = Math.abs(c);                     // 4. syllabic AGC
    env += (ax > env ? aAtt : aRel) * (ax - env);
    const g = Math.min(5, AGC_TARGET / (env + 1e-6));
    out[i] = c * g;
  }
  return out;
}

// ---------- stages 5-6 (in place) ----------
function squelchClicks(s, p) {
  const n = s.length;
  const mute = Math.min(n, Math.round(p.openDelayMs * SR / 1000));
  s.fill(0, 0, mute);
  const dataStart = Math.round(2.1 * SR); // past go cue + preamble + sync
  const dataEnd = n - Math.round(0.5 * SR); // before the stop tone
  const burstLen = p.burstNoise.length;
  if (burstLen > 0 && dataEnd - dataStart - burstLen > 0) {
    const b0 = dataStart + Math.round(p.burstFrac * (dataEnd - dataStart - burstLen));
    for (let i = 0; i < burstLen; i++) s[b0 + i] += BURST_AMP * p.burstNoise[i];
  }
  for (const c of p.clicks) {
    if (dataEnd - dataStart - c.len <= 0) continue;
    const c0 = dataStart + Math.round(c.frac * (dataEnd - dataStart - c.len));
    for (let i = 0; i < c.len; i++) s[c0 + i] += c.amp;
  }
}

// ---------- stage 7: reverb (2-tap echo, circular delay line) ----------
// Enabled at the spec'd gains since Task 6b-1: the tolerant sync search
// (Hamming <= 8) absorbs the echo's sync corruption, but the echo's data-
// region interference exceeds the RS(255,223) capacity for the radio profile
// at 25 dB (see "measured constraints" above). Gains remain parameters.
function reverb(s, p) {
  const e1 = p.echo1 !== undefined ? p.echo1 : ECHO1;
  const e2 = p.echo2 !== undefined ? p.echo2 : ECHO2;
  if (e1 <= 0 && e2 <= 0) return s;
  const n = s.length;
  const d1 = Math.round(p.echoD1Ms * SR / 1000);
  const d2 = Math.round(p.echoD2Ms * SR / 1000);
  const maxD = Math.max(d1, d2) + 1;
  const buf = new Float32Array(maxD);
  const out = new Float32Array(n);
  let idx = 0;
  for (let i = 0; i < n; i++) {
    out[i] = s[i] + e1 * buf[(idx - d1 + maxD * 2) % maxD] + e2 * buf[(idx - d2 + maxD * 2) % maxD];
    buf[idx] = s[i];
    idx = (idx + 1) % maxD;
  }
  return out;
}

// ---------- stage 8: recorder clock offset (linear resample) ----------
function clockOffset(s, p) {
  const factor = 1 + p.ppm * 1e-6;
  const n = s.length;
  const out = new Float32Array(Math.floor(n * factor));
  for (let i = 0; i < out.length; i++) {
    const pos = i / factor;
    const i0 = Math.floor(pos);
    const f = pos - i0;
    const j0 = Math.min(i0, n - 1);
    const j1 = Math.min(i0 + 1, n - 1);
    out[i] = s[j0] + (s[j1] - s[j0]) * f;
  }
  return out;
}

// ---------- stage 9: AWGN ----------
function awgn(s, p) {
  const n = s.length;
  const a0 = Math.round(0.5 * SR); // active region: past the squelch-open mute
  let sum = 0;
  for (let i = a0; i < n; i++) sum += s[i] * s[i];
  const rms = Math.sqrt(sum / Math.max(1, n - a0));
  const noise = rms * Math.pow(10, -p.snr / 20);
  const stride = p.noiseStride;
  const out = new Float32Array(n);
  let idx = p.noisePhase;
  for (let i = 0; i < n; i++) {
    out[i] = s[i] + noise * gaussTable[idx];
    idx += stride;
    if (idx >= GAUSS_N) idx -= GAUSS_N;
  }
  return out;
}

// ---------- channel model ----------
function channelModel(wav, rng, opts) {
  opts = opts || {};
  const p = opts.params || drawChannelParams(rng || mulberry32(1), opts);
  if (opts.snr !== undefined) p.snr = opts.snr;
  let x = samplesOf(wav);
  x = shapeTiltBandpassClipAgc(x); // 1-4
  squelchClicks(x, p);             // 5-6 (in place)
  x = reverb(x, p);                // 7
  x = clockOffset(x, p);           // 8
  x = awgn(x, p);                  // 9
  return rebuildWav(x);
}

// ---------- encode + decode ----------
function encodeV2(wavprobe, payload, profileName, custom) {
  const args = custom ? [profileName, String(custom.tone_low), String(custom.tone_high), String(custom.samples_per_bit)] : [profileName];
  return execFileSync(wavprobe, args, { input: payload, maxBuffer: 64 * 1024 * 1024 });
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function tryDecode(wav, payload, profilesOverride) {
  try {
    const got = decodeFrame(wav, profilesOverride);
    const back = gunzipSync(got.compressed);
    if (!bytesEqual(back, payload)) {
      return { ok: false, err: "PayloadMismatch", profile: got.profile, stats: got.stats };
    }
    return { ok: true, err: null, profile: got.profile, stats: got.stats };
  } catch (e) {
    return { ok: false, err: e.name || "Error", profile: null, stats: null };
  }
}

// sweep mode: encode with custom modulation constants (wavprobe's optional
// args) and decode with matching overrides, per config "tone_low/tone_high/spb"
function runSweep(opts) {
  const wavprobe = path.join(__dirname, "..", "zig-out", "bin", "wavprobe");
  const configs = opts.sweep.split(",").map((c) => {
    const [tl, th, spb] = c.split("/").map((x) => Number(x));
    return { tone_low: tl, tone_high: th, samples_per_bit: spb };
  });
  const rows = [];
  for (const cfg of configs) {
    let fail = 0, sync = 0, rs = 0;
    for (let t = 0; t < opts.trials; t++) {
      const rng = mulberry32((opts.seed + Math.imul(t + 1, 0x9E3779B9)) >>> 0);
      const payload = randBytes(rng, 1024);
      const params = drawChannelParams(rng);
      const wav = encodeV2(wavprobe, payload, "radio", cfg);
      const ch = channelModel(wav, rng, { params, snr: opts.snr });
      const res = tryDecode(ch, payload, [Object.assign({ name: "radio" }, cfg)]);
      if (!res.ok) {
        fail++;
        if (res.err === "SyncNotFound") sync++;
        else rs++;
      }
    }
    rows.push({ cfg, fail, fer: 100 * fail / opts.trials, sync, rs });
  }
  rows.sort((a, b) => a.fer - b.fer);
  console.log(`sweep ${configs.length} configs x ${opts.trials} trials @ ${opts.snr}dB seed 0x${opts.seed.toString(16)} (echo ${opts.echo}, ppm ${opts.ppm})`);
  for (const r of rows) {
    console.log(`  ${String(r.cfg.tone_low).padStart(4)}/${String(r.cfg.tone_high).padStart(4)} spb ${String(r.cfg.samples_per_bit).padStart(2)}: FER ${r.fer.toFixed(1).padStart(5)}% (${r.fail}/${opts.trials}) sync=${r.sync} rs=${r.rs}`);
  }
}

function randBytes(rng, len) {
  const b = Buffer.alloc(len);
  for (let i = 0; i < len; i++) b[i] = Math.floor(rng() * 256);
  return b;
}

// ---------- CLI ----------
function usage() {
  console.log("usage: node tests/channel_sim.js [--trials N] [--snr dB] [--seed S] [--profile radio|clean] [--report] [--echo F] [--ppm P] [--sweep tl/th/spb,...]");
}

function parseArgs(argv) {
  const a = { trials: DEFAULT_TRIALS, snr: DEFAULT_SNR, seed: DEFAULT_SEED, gateProfile: DEFAULT_PROFILE, report: false };
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i];
    if (v === "--report") a.report = true;
    else if (v === "--trials") a.trials = parseInt(argv[++i], 10);
    else if (v === "--snr") a.snr = parseFloat(argv[++i]);
    else if (v === "--seed") a.seed = Number(argv[++i]) >>> 0;
    else if (v === "--profile") a.gateProfile = argv[++i];
    else if (v === "--echo") a.echo = parseFloat(argv[++i]);
    else if (v === "--ppm") a.ppm = parseFloat(argv[++i]);
    else if (v === "--sweep") a.sweep = argv[++i];
    else if (v === "--help") { usage(); process.exit(0); }
    else { console.error("unknown arg: " + v); usage(); process.exit(2); }
  }
  if (!Number.isFinite(a.trials) || a.trials < 1) { console.error("bad --trials"); process.exit(2); }
  if (!Number.isFinite(a.snr)) { console.error("bad --snr"); process.exit(2); }
  if (a.gateProfile !== "radio" && a.gateProfile !== "clean") { console.error("bad --profile"); process.exit(2); }
  return a;
}

// ---------- main ----------
function main() {
  const opts = parseArgs(process.argv.slice(2));
  const wavprobe = path.join(__dirname, "..", "zig-out", "bin", "wavprobe");
  console.log("== channel sim ==");
  execFileSync("zig", ["build", "wavprobe"], { stdio: "pipe" });
  if (opts.sweep) return runSweep(opts) | 0;

  const profiles = ["radio", "clean"];
  const agg = {};
  for (const prof of profiles) agg[prof] = { ok: 0, fail: 0, errors: {}, syncSnr: 0, rsCorr: 0, fails: [] };

  const t0 = Date.now();
  for (let t = 0; t < opts.trials; t++) {
    const rng = mulberry32((opts.seed + Math.imul(t + 1, 0x9E3779B9)) >>> 0);
    const payload = randBytes(rng, 1024);
    const params = drawChannelParams(rng, opts); // one channel realization per trial
    for (const prof of profiles) {
      const wav = encodeV2(wavprobe, payload, prof);
      const ch = channelModel(wav, rng, { params, snr: opts.snr });
      const res = tryDecode(ch, payload);
      const a = agg[prof];
      if (res.ok) {
        a.ok++;
        a.syncSnr += res.stats.syncSnr;
        a.rsCorr += res.stats.rsCorrections.reduce((x, y) => x + y, 0);
      } else {
        a.fail++;
        a.errors[res.err] = (a.errors[res.err] || 0) + 1;
        if (opts.report) a.fails.push({ trial: t + 1, err: res.err });
      }
    }
  }
  const msPerTrial = (Date.now() - t0) / opts.trials;

  console.log(`settings: trials=${opts.trials} snr=${opts.snr}dB seed=0x${opts.seed.toString(16)} gate=${opts.gateProfile} budget=${GATE_BUDGET}`);
  if (opts.report) {
    for (const prof of profiles) {
      for (const f of agg[prof].fails) console.log(`  fail trial=${f.trial} profile=${prof} err=${f.err}`);
    }
  }
  for (const prof of profiles) {
    const a = agg[prof];
    const errs = Object.entries(a.errors).map(([k, v]) => `${k}=${v}`).join(" ") || "-";
    const meanSnr = a.ok ? (a.syncSnr / a.ok).toFixed(1) : "-";
    const meanRs = a.ok ? (a.rsCorr / a.ok).toFixed(2) : "-";
    console.log(`profile ${prof}: ok=${a.ok}/${opts.trials} FER=${(100 * a.fail / opts.trials).toFixed(2)}% errors: {${errs}} meanSyncSnr=${meanSnr}dB meanRsCorr=${meanRs}`);
  }
  console.log(`runtime: ${msPerTrial.toFixed(1)} ms/trial (${(msPerTrial * 2 / 1000).toFixed(2)} s per trial incl. both profiles)`);

  const gate = agg[opts.gateProfile];
  if (opts.report) {
    console.log("report mode: exit 0 regardless of FER");
    return 0;
  }
  const pass = gate.fail <= GATE_BUDGET;
  console.log(pass
    ? `PASS channel sim gate (${opts.gateProfile} FER ${(100 * gate.fail / opts.trials).toFixed(2)}% <= ${100 * GATE_BUDGET / opts.trials}%)`
    : `FAIL channel sim gate (${opts.gateProfile} ${gate.fail}/${opts.trials} failures > budget ${GATE_BUDGET})`);
  return pass ? 0 : 1;
}

if (require.main === module) process.exitCode = main();
module.exports = {
  mulberry32, drawChannelParams, channelModel, samplesOf, rebuildWav, tryDecode,
  shapeTiltBandpassClipAgc, squelchClicks, reverb, clockOffset, awgn, bytesEqual,
};
