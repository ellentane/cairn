"use strict";
// Audio round-trip: zig encode -> node decode -> byte equality + CRC vector.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { decodeWavBytes, crc32 } = require("../src/decoder.js");

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

console.log(failures ? `\n${failures} FAILURE(S)` : "\nAUDIO TESTS GREEN");
process.exitCode = failures ? 1 : 0;
