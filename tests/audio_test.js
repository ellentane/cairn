"use strict";
// Audio round-trip: zig encode -> node decode -> byte equality + CRC vector.
const fs = require("fs");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");
const { decodeFrame, crc32, demodIQ, gunzipSync } = require("../src/decoder.js");

let failures = 0;
function check(name, cond) {
  if (cond) console.log("PASS " + name);
  else { failures++; console.error("FAIL " + name); }
}

// 0. clean slate: --audio always regenerates decode.html, and the stale
// replacement test below plants its own garbage first — remove leftovers
for (const p of ["/tmp/cairn-audio-page.html", "/tmp/cairn-audio-site.wav", "/tmp/cairn-audio-clean.wav", "/tmp/cairn-audio-decode.html", "/tmp/decode.html"]) {
  fs.rmSync(p, { force: true });
}

// 1. CRC vector
check("crc32 iso-hdlc vector", crc32(new TextEncoder().encode("123456789")) === 0xCBF43926);

// 2. build example -> --audio (v2 frame, default radio profile) -> decode
// via decodeFrame + gunzipSync -> byte equality
const root = path.join(__dirname, "..");
execFileSync(path.join(root, "zig-out/bin/cairn"), ["build", "example/index.md", "--output", "/tmp/cairn-audio-page.html"], { stdio: "pipe" });
const page = fs.readFileSync("/tmp/cairn-audio-page.html");
const wavPath = "/tmp/cairn-audio-site.wav";
execFileSync(path.join(root, "zig-out/bin/cairn"), ["build", "example/index.md", "--output", "/tmp/cairn-audio-page.html", "--audio", wavPath], { stdio: "pipe" });
const wav = fs.readFileSync(wavPath);
const got = decodeFrame(wav);
check("audio round-trip decodes with the v2 decoder", got.profile === "radio");
const decoded = gunzipSync(got.compressed);
check("audio round-trip byte equality", Buffer.compare(Buffer.from(decoded), page) === 0);
const decodePath = path.join(path.dirname(wavPath), "decode.html");
const decodeHtml = fs.readFileSync(decodePath, "utf8");
check("decode.html generated", fs.existsSync(decodePath));
check("decode.html splices the v2 decoder", decodeHtml.includes("function decodeFrame") && decodeHtml.includes("tone_low: 1200") && decodeHtml.includes("tone_high: 2300"));
check("decode.html has no leftover placeholder", !decodeHtml.includes("/*__CAIRN_DECODER__*/"));

// 2b. --audio always regenerates decode.html: a pre-planted stale file is
// replaced by the build
const garbage = "<html><body>STALE</body></html>";
fs.writeFileSync(decodePath, garbage);
execFileSync(path.join(root, "zig-out/bin/cairn"), ["build", "example/index.md", "--output", "/tmp/cairn-audio-page.html", "--audio", wavPath], { stdio: "pipe" });
const fresh = fs.readFileSync(decodePath, "utf8");
check("stale decode.html replaced", !fresh.includes("STALE") && fresh.includes("function decodeFrame"));

// 2c. --audio-profile clean selects the clean link profile
const cleanWavPath = "/tmp/cairn-audio-clean.wav";
execFileSync(path.join(root, "zig-out/bin/cairn"), ["build", "example/index.md", "--output", "/tmp/cairn-audio-page.html", "--audio", cleanWavPath, "--audio-profile", "clean"], { stdio: "pipe" });
const cleanGot = decodeFrame(fs.readFileSync(cleanWavPath));
check("clean profile wav decodes as clean", cleanGot.profile === "clean");
check("clean profile round-trip", Buffer.compare(Buffer.from(gunzipSync(cleanGot.compressed)), page) === 0);

// 2d. --audio-profile rejects unknown values cleanly
const bad = spawnSync(path.join(root, "zig-out/bin/cairn"), ["build", "example/index.md", "--output", "/tmp/cairn-audio-page.html", "--audio-profile", "bogus"], { encoding: "utf8" });
check("--audio-profile bogus fails", bad.status !== 0);
check("--audio-profile bogus error message", /invalid --audio-profile/.test(bad.stderr || ""));

// 3. v2 gzip payload path, cross-inflate checkpoint: the zig encoder is the
// only gzip producer, node zlib the consumer. gzprobe (stdin -> gzip ->
// stdout, zig-out/bin) is a `zig build gzprobe` artifact; rebuild it so the
// test always exercises the current audio.zig.
execFileSync("zig", ["build", "gzprobe"], { stdio: "pipe" });
const zlib = require("zlib");
const gzprobe = path.join(root, "zig-out/bin/gzprobe");
function zigGzip(buf) {
  return execFileSync(gzprobe, [], { input: buf });
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
const payloads = {
  "empty payload": Buffer.alloc(0),
  "1-byte payload": Buffer.from([0x42]),
  "40 KB pseudo-random payload": xorshift32(0x9E3779B9, 40 * 1024),
  "example page": page,
};
for (const [name, original] of Object.entries(payloads)) {
  const zigGz = zigGzip(original);
  check(`zig gzip header is 1f 8b 08 (${name})`, zigGz[0] === 0x1f && zigGz[1] === 0x8b && zigGz[2] === 0x08);
  check(`zig gzip -> node gunzipSync (${name})`, Buffer.compare(zlib.gunzipSync(zigGz), original) === 0);
  check(`decoder.gunzipSync seam (${name})`, Buffer.compare(Buffer.from(gunzipSync(zigGz)), original) === 0);
}
const pageGz = zigGzip(page);
check("example page compresses below half size", pageGz.length < page.length / 2);

// 4. I/Q quadrature demod: the decision must be invariant to carrier phase.
// v1's |sin-only| correlator flips at phi=pi/2 (proven in the v2 audit) — this
// test exists to prove the fix and prevent regression.
// 12 spb @ 19200: 1600 Bd, tones 1200 (mark) / 2000 (space)
const SR = 19200, SPB = 12;
const MARK = 1200, SPACE = 2000;

// a 2-bit symbol: mark then space, each SPB samples, at carrier phase phi
const phases = [0, Math.PI / 2, Math.PI, 1.3, 2.7];
for (const phi of phases) {
  const s = new Float64Array(2 * SPB);
  for (let t = 0; t < 2 * SPB; t++) {
    const f = t < SPB ? MARK : SPACE;
    s[t] = 12000 * Math.sin(2 * Math.PI * f * t / SR + phi);
  }
  const bits = demodIQ(s, { sr: SR, spb: SPB, tones: [MARK, SPACE] });
  check(`IQ phase ${phi.toFixed(2)} decodes [1,0]`, bits.length === 2 && bits[0] === 1 && bits[1] === 0);
}

console.log(failures ? `\n${failures} FAILURE(S)` : "\nAUDIO TESTS GREEN");
process.exitCode = failures ? 1 : 0;
