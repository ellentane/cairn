"use strict";
// Audio round-trip: zig encode -> node decode -> byte equality + CRC vector.
const fs = require("fs");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");
const { decodeFrame, decodeFrameSamples, crc32, demodIQ, gunzipSync } = require("../src/decoder.js");

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

// 5. decodeFrameSamples: the samples-based entry (what decode.html's
// decodeAudioData path feeds) must match decodeFrame byte-for-byte, and
// tolerate any capture rate (spb is derived from sr)
{
  const samples = new Int16Array(wav.buffer, wav.byteOffset + 44, (wav.length - 44) / 2);
  const gotS = decodeFrameSamples(samples, 19200);
  check("decodeFrameSamples decodes the radio wav", gotS.profile === "radio");
  check("decodeFrameSamples payload byte-exact", Buffer.compare(Buffer.from(gunzipSync(gotS.compressed)), page) === 0);
  check("decodeFrameSamples stats shape", typeof gotS.stats.syncSnr === "number" && Array.isArray(gotS.stats.rsCorrections));
  const half = new Int16Array(Math.floor(samples.length / 2));
  for (let i = 0; i < half.length; i++) half[i] = samples[i * 2];
  const gotHalf = decodeFrameSamples(half, 9600);
  check("decodeFrameSamples decodes at a foreign rate (9600 Hz)",
    gotHalf.profile === "radio" && Buffer.compare(Buffer.from(gunzipSync(gotHalf.compressed)), page) === 0);
}

// 6. decode.html tpl: replicate main.zig's splice, then parse the inline JS
// and drive the file handler headlessly. Node 26 has DecompressionStream and
// Blob/Response, so the real inflate path runs; only DOM/window are stubbed.
// The app IIFE runs in the main realm with the real module decoder injected as
// the CairnDecoder global (the embedded copy is exercised by the parse checks
// and by the built decode.html; running it needs a vm sandbox, which runs the
// decoder ~7x slower — measured 53 s for one decode of the example wav).
const tpl = fs.readFileSync(path.join(root, "tools/decode.html.tpl"), "utf8");
const decoderSrc = fs.readFileSync(path.join(root, "src/decoder.js"), "utf8");
const spliced = tpl.replace("/*__CAIRN_DECODER__*/", decoderSrc);
check("tpl splice leaves no placeholder", !spliced.includes("/*__CAIRN_DECODER__*/"));
const scriptMatch = spliced.match(/<script>([\s\S]*)<\/script>/);
check("tpl has one script block", !!scriptMatch && (spliced.match(/<script>/g) || []).length === 1);
let parseOk = true;
try { new Function(scriptMatch[1]); } catch (e) { parseOk = false; }
check("tpl inline JS parses (syntax)", parseOk);
const genHtml = fs.readFileSync(decodePath, "utf8");
const genMatch = genHtml.match(/<script>([\s\S]*)<\/script>/);
let genOk = true;
try { new Function(genMatch[1]); } catch (e) { genOk = false; }
check("generated decode.html JS parses (syntax)", !!genMatch && genOk);

// 6a. mic path: the v1-era artefacts (analyser polling, 64-chunk window, fake
// wav header, hardcoded 19200) are gone; the v2 capture is present
const appTpl = scriptMatch[1].slice(decoderSrc.length);
check("tpl mic: v1 analyser polling removed",
  !appTpl.includes("analyser") && !appTpl.includes("fftSize") && !appTpl.includes("getFloatTimeDomainData"));
check("tpl mic: v1 fake wav header + hardcoded rate removed",
  !appTpl.includes("0x52,0x49,0x46,0x46") && !appTpl.includes("19200") && !appTpl.includes("micState"));
check("tpl mic: v2 AudioWorklet capture present",
  appTpl.includes("AudioWorkletProcessor") && appTpl.includes("cairn-capture") && appTpl.includes("micChunkLen"));
check("tpl mic: ScriptProcessor fallback present", appTpl.includes("createScriptProcessor"));
check("tpl mic: shared showDecoded helper present", appTpl.includes("function showDecoded"));
const genApp = genMatch[1].slice(decoderSrc.length);
check("generated decode.html mic: v1 artefacts absent from the build",
  !genApp.includes("analyser") && !genApp.includes("fftSize") && !genApp.includes("micState") && !genApp.includes("19200"));

// small page for a fast probe: the wire is always a full interleave group
// (4080 bytes ≈ 24 s of radio audio), so a small page decodes quickly
const probeMd = "/tmp/opencode/cairn-probe.md";
fs.writeFileSync(probeMd, "# Probe\n\ncairn probe page " + "y".repeat(700) + "\n");
execFileSync(path.join(root, "zig-out/bin/cairn"), ["build", probeMd, "--output", "/tmp/opencode/cairn-probe.html", "--audio", "/tmp/opencode/cairn-probe.wav"], { stdio: "pipe" });
const probePage = fs.readFileSync("/tmp/opencode/cairn-probe.html");
const probeWav = fs.readFileSync("/tmp/opencode/cairn-probe.wav");

(async function () {
  const s16wav = new Int16Array(probeWav.buffer, probeWav.byteOffset + 44, (probeWav.length - 44) / 2);
  const f32wav = new Float32Array(s16wav.length);
  for (let i = 0; i < s16wav.length; i++) f32wav[i] = s16wav[i] / 32767;
  const audioBuffer = { getChannelData: () => f32wav, sampleRate: 19200 };
  let lastSrc = null;
  let lastWorkletNode = null;
  let lastSP = null;
  function FakeAudioWorkletNode() {
    const node = { port: { onmessage: null }, connect: () => {}, disconnect: () => {} };
    lastWorkletNode = node;
    return node;
  }
  function FakeAudioContext() {}
  FakeAudioContext.prototype.sampleRate = 19200;
  FakeAudioContext.prototype.audioWorklet = { addModule: async () => {} };
  FakeAudioContext.prototype.decodeAudioData = function (ab, ok, err) {
    if (ok) queueMicrotask(() => ok(audioBuffer));
    return Promise.resolve(audioBuffer);
  };
  FakeAudioContext.prototype.createBufferSource = function () {
    lastSrc = { buffer: null, loop: false, connect: () => {}, start: () => {} };
    return lastSrc;
  };
  FakeAudioContext.prototype.destination = {};
  FakeAudioContext.prototype.createMediaStreamSource = function () { return { connect: () => {} }; };
  FakeAudioContext.prototype.createScriptProcessor = function () {
    lastSP = { connect: () => {}, disconnect: () => {}, onaudioprocess: null };
    return lastSP;
  };

  const els = {};
  const handlers = {};
  for (const id of ["status", "out", "download", "file", "transmit", "mic", "loop"]) {
    els[id] = {
      textContent: "", hidden: true, href: "", download: "",
      addEventListener: (ev, cb) => { handlers[id + ":" + ev] = cb; },
    };
  }
  const document = { getElementById: (id) => els[id] };
  const api = require("../src/decoder.js");
  const appCode = scriptMatch[1].slice(decoderSrc.length);
  const runTpl = new Function("document", "window", "navigator", "URL", "CairnDecoder", appCode);
  const fakeStream = { getTracks: () => [{ stop() {} }] };
  const micNav = { mediaDevices: { getUserMedia: async () => fakeStream } };
  const micWindow = { AudioContext: FakeAudioContext, AudioWorkletNode: FakeAudioWorkletNode };
  runTpl(document, micWindow, micNav, { createObjectURL: () => "blob:probe" }, api);
  const fileOf = (bytes) => ({ arrayBuffer: async () => { const ab = new ArrayBuffer(bytes.length); new Uint8Array(ab).set(bytes); return ab; } });

  await handlers["file:change"].call({ files: [fileOf(probeWav)] });
  check("file path: RIFF wav decodes to the page", els.out.textContent === probePage.toString("utf8"));
  check("file path: stats readout", /^Decoded \d+ bytes, CRC verified, sync SNR \d+(\.\d+)? dB, 0 codewords corrected\.$/.test(els.status.textContent));
  check("file path: download link revealed", els.download.hidden === false && els.download.download === "decoded.html");

  const m4aBytes = Buffer.from([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20]);
  await handlers["file:change"].call({ files: [fileOf(m4aBytes)] });
  check("file path: decodeAudioData path (m4a) decodes", els.out.textContent === probePage.toString("utf8"));
  check("file path: decodeAudioData stats readout", /^Decoded \d+ bytes, CRC verified, sync SNR \d+(\.\d+)? dB, 0 codewords corrected\.$/.test(els.status.textContent));

  const silence = Buffer.concat([probeWav.subarray(0, 44), Buffer.alloc(19200 * 2)]);
  await handlers["file:change"].call({ files: [fileOf(silence)] });
  check("file path: SyncNotFound taxonomy", els.status.textContent === "no cairn frame found in the audio (check the recording)");

  handlers["loop:click"].call(els.loop);
  check("loop toggle on", els.loop.textContent === "loop: on");
  await new Promise((r) => setTimeout(r, 5));
  handlers["transmit:click"]();
  await new Promise((r) => setTimeout(r, 5));
  check("transmit honors loop flag", !!lastSrc && lastSrc.loop === true);
  handlers["loop:click"].call(els.loop);
  await new Promise((r) => setTimeout(r, 5));
  handlers["transmit:click"]();
  await new Promise((r) => setTimeout(r, 5));
  check("transmit honors loop off", !!lastSrc && lastSrc.loop === false);

  // 6c. mic path probe (AudioWorklet): start recording, feed the accumulated
  // chunks from the probe wav (4096-frame pieces; the fake context runs at
  // 19200 so the wav needs no resampling), stop, and assert the decoded page
  // with stats. The worklet node is faked — the tpl only needs its port —
  // so the real accumulate/stop/decode path is exercised end to end.
  const CHUNK = 4096;
  els.out.textContent = "";
  await handlers["mic:click"]();
  check("mic start: worklet node wired",
    !!lastWorkletNode && typeof lastWorkletNode.port.onmessage === "function");
  check("mic start: recording status",
    /^Listening… \(recording \d+(\.\d+)?s\) — stop when the transmission ends$/.test(els.status.textContent));
  for (let off = 0; off < f32wav.length; off += CHUNK) {
    lastWorkletNode.port.onmessage({ data: f32wav.subarray(off, Math.min(off + CHUNK, f32wav.length)) });
  }
  await handlers["mic:click"]();
  check("mic stop: worklet capture decodes to the page", els.out.textContent === probePage.toString("utf8"));
  check("mic stop: stats readout",
    /^Decoded \d+ bytes, CRC verified, sync SNR \d+(\.\d+)? dB, 0 codewords corrected\.$/.test(els.status.textContent));

  // 6d. ScriptProcessor fallback probe: re-run the app with AudioWorkletNode
  // absent, drive onaudioprocess directly, and decode the same wav
  runTpl(document, { AudioContext: FakeAudioContext }, micNav, { createObjectURL: () => "blob:probe" }, api);
  els.out.textContent = "";
  await handlers["mic:click"]();
  check("mic fallback: scriptprocessor node wired",
    !!lastSP && typeof lastSP.onaudioprocess === "function");
  for (let off = 0; off < f32wav.length; off += CHUNK) {
    lastSP.onaudioprocess({ inputBuffer: { getChannelData: () => f32wav.subarray(off, Math.min(off + CHUNK, f32wav.length)) } });
  }
  await handlers["mic:click"]();
  check("mic fallback: scriptprocessor capture decodes to the page", els.out.textContent === probePage.toString("utf8"));
  check("mic fallback: status readout",
    /^Decoded \d+ bytes, CRC verified, sync SNR \d+(\.\d+)? dB, 0 codewords corrected\.$/.test(els.status.textContent));

  console.log(failures ? `\n${failures} FAILURE(S)` : "\nAUDIO TESTS GREEN");
  process.exitCode = failures ? 1 : 0;
})();
