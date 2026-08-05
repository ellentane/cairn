"use strict";
// RS(255,223) codec + depth-16 interleave tests: shared pinned vectors (both
// JS and Zig implementations must pass byte-identical parity).
const {
  K, N, NSYM, dataVector, parity, errorPositions, corruptedCodeword,
} = require("./rs_vectors.js");
const { rsEncode, rsDecode, deinterleave, gfMul, gfExp, gfLog } = require("../src/decoder.js");

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

// deterministic PRNG (LCG) so error patterns are reproducible across runs
function makeRng(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s; };
}

// wire map per spec: wire position b*16 + k -> codeword k, byte index b
function wire(codewords, depth) {
  const len = codewords[0].length;
  const out = new Uint8Array(codewords.length * len);
  for (let b = 0; b < len; b++)
    for (let k = 0; k < codewords.length; k++)
      out[b * depth + k] = codewords[k][b];
  return out;
}

function codewordFromVector1() {
  const cw = new Uint8Array(N);
  cw.set(dataVector(), 0);
  cw.set(parity, K);
  return cw;
}

// 1. encode parity == pinned vector 1 parity (byte-exact)
{
  const cw = rsEncode(dataVector());
  check("rsEncode length 255", cw.length === N);
  check("rsEncode parity matches pinned vector 1", bytesEqual(cw.slice(K), parity));
  check("rsEncode keeps data bytes intact", bytesEqual(cw.slice(0, K), dataVector()));
}

// 2. clean codeword round-trips
{
  const cw = codewordFromVector1();
  const dec = rsDecode(cw);
  check("rsDecode(clean) === data", dec !== null && bytesEqual(dec, dataVector()));
}

// 3. pinned vector 2: 8 errors corrected via the Berlekamp-Massey path
{
  const dec = rsDecode(corruptedCodeword());
  check("rsDecode(corrupted, 8 errors) === data", dec !== null && bytesEqual(dec, dataVector()));
}

// 4. t=16 boundary: 16 errors at arbitrary distinct positions
{
  const rng = makeRng(42);
  const pos = [];
  while (pos.length < 16) {
    const p = rng() % N;
    if (!pos.includes(p)) pos.push(p);
  }
  const cw = codewordFromVector1();
  for (const p of pos) cw[p] ^= (rng() & 0xff) || 1;
  const dec = rsDecode(cw);
  check("rsDecode with 16 errors === data", dec !== null && bytesEqual(dec, dataVector()));
}

// 5. 17 errors -> null (uncorrectable, no silent corruption)
{
  const rng = makeRng(7);
  const pos = [];
  while (pos.length < 17) {
    const p = rng() % N;
    if (!pos.includes(p)) pos.push(p);
  }
  const cw = codewordFromVector1();
  for (const p of pos) cw[p] ^= (rng() & 0xff) || 1;
  check("rsDecode with 17 errors -> null", rsDecode(cw) === null);
}

// 6. interleave/deinterleave round-trip: 16 codewords -> wire -> deinterleave
{
  const blocks = [];
  for (let k = 0; k < 16; k++) blocks.push(rsEncode(dataVector()));
  const w = wire(blocks, 16);
  const out = deinterleave(w, 16, N);
  let ok = out.length === 16;
  for (let k = 0; ok && k < 16; k++) ok = bytesEqual(out[k], blocks[k]);
  check("interleave/deinterleave round-trip 16 codewords", ok);
}

// 7. burst: 16 consecutive bytes of ONE codeword corrupted in the wire
// stream (they sit 16 bytes apart on the wire) -> every codeword decodes
{
  const blocks = [];
  for (let k = 0; k < 16; k++) blocks.push(rsEncode(dataVector()));
  const w = wire(blocks, 16);
  const burst = blocks[0]; // corrupt bytes 0..15 of codeword 0
  for (let b = 0; b < 16; b++) w[b * 16 + 0] = burst[b] ^ 0xa5;
  const out = deinterleave(w, 16, N);
  let ok = out.length === 16;
  for (let k = 0; ok && k < 16; k++) {
    const dec = rsDecode(out[k]);
    ok = dec !== null && bytesEqual(dec, dataVector());
  }
  check("16-byte burst on one codeword: all 16 decode", ok);
}

// 8. partial group: 3 codewords round-trip. The wire map is row-major at full
// depth (position b*16 + k); with fewer than 16 codewords the remaining slots
// are zero-padded (Task 4 pads the same way), and deinterleave must still
// recover the real codewords.
{
  const blocks = [];
  for (let k = 0; k < 16; k++) blocks.push(k < 3 ? rsEncode(dataVector()) : new Uint8Array(N));
  const w = wire(blocks, 16);
  const out = deinterleave(w, 16, N);
  let ok = out.length === 16;
  for (let k = 0; ok && k < 3; k++) ok = bytesEqual(out[k], blocks[k]);
  for (let k = 3; ok && k < 16; k++) ok = bytesEqual(out[k], blocks[k]);
  check("partial group of 3 codewords (zero-padded) round-trip", ok);
}

// 9. GF tables sanity: table-driven multiply agrees with carry-less
// multiply + 0x11D reduction on 100 random pairs (independent of the tables)
{
  const rng = makeRng(99);
  let ok = true;
  for (let t = 0; t < 100; t++) {
    const a = rng() & 0xff, b = rng() & 0xff;
    let z = 0, x = a, y = b;
    while (y) {
      if (y & 1) z ^= x;
      y >>>= 1;
      x <<= 1;
      if (x & 0x100) x ^= 0x11d;
    }
    if (gfMul(a, b) !== z) { ok = false; break; }
  }
  check("gfMul matches carry-less multiply + 0x11D", ok);
  check("gfExp/gfLog are inverse tables", gfExp[gfLog[0x5a]] === 0x5a && gfLog[gfExp[200]] === 200);
}

console.log(failures ? `\n${failures} FAILURE(S)` : "\nRS TESTS GREEN");
process.exitCode = failures ? 1 : 0;
