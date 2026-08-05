"use strict";
// Audio round-trip: zig encode -> node decode -> byte equality + CRC vector.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { decodeWavBytes, crc32, demodIQ } = require("../src/decoder.js");

let failures = 0;
function check(name, cond) {
  if (cond) console.log("PASS " + name);
  else { failures++; console.error("FAIL " + name); }
}

// 0. clean slate: decode.html generation is only-if-absent, so a stale file
// from an earlier run would make the existence check pass vacuously
for (const p of ["/tmp/cairn-audio-page.html", "/tmp/cairn-audio-site.wav", "/tmp/cairn-audio-decode.html", "/tmp/decode.html"]) {
  fs.rmSync(p, { force: true });
}

// 1. CRC vector
check("crc32 iso-hdlc vector", crc32(new TextEncoder().encode("123456789")) === 0xCBF43926);

// 2. build example -> --audio -> decode -> byte equality
const root = path.join(__dirname, "..");
execFileSync(path.join(root, "zig-out/bin/cairn"), ["build", "example/index.md", "--output", "/tmp/cairn-audio-page.html"], { stdio: "pipe" });
const page = fs.readFileSync("/tmp/cairn-audio-page.html");
const wavPath = "/tmp/cairn-audio-site.wav";
execFileSync(path.join(root, "zig-out/bin/cairn"), ["build", "example/index.md", "--output", "/tmp/cairn-audio-page.html", "--audio", wavPath], { stdio: "pipe" });
const wav = fs.readFileSync(wavPath);
const decoded = decodeWavBytes(wav);
check("audio round-trip byte equality", Buffer.compare(Buffer.from(decoded), page) === 0);
check("decode.html generated", fs.existsSync(path.join(path.dirname(wavPath), "decode.html")));

// 3. I/Q quadrature demod: the decision must be invariant to carrier phase.
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
