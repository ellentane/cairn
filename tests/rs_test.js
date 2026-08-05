"use strict";
// RS(255,223) codec + depth-16 interleave tests: shared pinned vectors (both
// JS and Zig implementations must pass byte-identical parity).
const {
  dataVector, data2Vector, parity, parity2, errorPositions, corruptedCodeword,
} = require("./rs_vectors.js");
const { rs } = require("../src/decoder.js");

const { N, K, NSYM } = rs;

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

// distinct data per block: block k uses data bytes (i*7+3+k*31) & 0xff, so an
// interleave map that permutes codewords fails the round-trip
function distinctBlocks(count) {
  const blocks = [];
  for (let k = 0; k < count; k++) {
    const d = new Uint8Array(K);
    for (let i = 0; i < K; i++) d[i] = (i * 7 + 3 + k * 31) & 0xff;
    blocks.push(rs.encode(d));
  }
  return blocks;
}

// 1. encode parity == pinned vector 1 parity (byte-exact)
{
  const cw = rs.encode(dataVector());
  check("rsEncode length 255", cw.length === N);
  check("rsEncode parity matches pinned vector 1", bytesEqual(cw.slice(K), parity));
  check("rsEncode keeps data bytes intact", bytesEqual(cw.slice(0, K), dataVector()));
}

// 2. clean codeword round-trips
{
  const cw = codewordFromVector1();
  const dec = rs.decode(cw);
  check("rsDecode(clean) === data", dec !== null && bytesEqual(dec, dataVector()));
}

// 3. pinned vector 2: 8 errors corrected via the Berlekamp-Massey path
{
  const dec = rs.decode(corruptedCodeword());
  check("rsDecode(corrupted, 8 errors) === data", dec !== null && bytesEqual(dec, dataVector()));
}

// 4. second pinned vector: (i*13+7)&0xff encodes to the same parity in JS
// and Zig (independent pin, not byte-identical to vector 1 by coincidence)
{
  const cw = rs.encode(data2Vector());
  check("rsEncode parity matches pinned vector 3 (data2)", bytesEqual(cw.slice(K), parity2));
}

// 5. t=16 boundary: 16 errors at arbitrary distinct positions
{
  const rng = makeRng(42);
  const pos = [];
  while (pos.length < 16) {
    const p = rng() % N;
    if (!pos.includes(p)) pos.push(p);
  }
  const cw = codewordFromVector1();
  for (const p of pos) cw[p] ^= (rng() & 0xff) || 1;
  const dec = rs.decode(cw);
  check("rsDecode with 16 errors === data", dec !== null && bytesEqual(dec, dataVector()));
}

// 6. 17 errors -> null (uncorrectable, no silent corruption)
{
  const rng = makeRng(7);
  const pos = [];
  while (pos.length < 17) {
    const p = rng() % N;
    if (!pos.includes(p)) pos.push(p);
  }
  const cw = codewordFromVector1();
  for (const p of pos) cw[p] ^= (rng() & 0xff) || 1;
  check("rsDecode with 17 errors -> null", rs.decode(cw) === null);
}

// 7. interleave/deinterleave round-trip with DISTINCT blocks + explicit wire
// order: wire[0]=blocks[0][0], wire[1]=blocks[1][0], wire[16]=blocks[0][1]
{
  const blocks = distinctBlocks(16);
  const w = wire(blocks, 16);
  check("wire order row-major (w0=c0[0], w1=c1[0], w16=c0[1])",
    w[0] === blocks[0][0] && w[1] === blocks[1][0] && w[16] === blocks[0][1]);
  const out = rs.deinterleave(w, 16, N);
  let ok = out.length === 16;
  for (let k = 0; ok && k < 16; k++) ok = bytesEqual(out[k], blocks[k]);
  check("interleave/deinterleave round-trip 16 distinct codewords", ok);
}

// 8. concentrated burst: 16 consecutive bytes of ONE codeword corrupted in
// the wire stream (they sit 16 bytes apart on the wire) -> every codeword
// decodes (t=16 stress on a single codeword)
{
  const blocks = distinctBlocks(16);
  const w = wire(blocks, 16);
  for (let b = 0; b < 16; b++) w[b * 16 + 0] = blocks[0][b] ^ 0xa5;
  const out = rs.deinterleave(w, 16, N);
  let ok = out.length === 16;
  for (let k = 0; ok && k < 16; k++) {
    const dec = rs.decode(out[k]);
    ok = dec !== null && bytesEqual(dec, blocks[k].slice(0, K));
  }
  check("16-byte burst on one codeword: all 16 decode", ok);
}

// 9. genuine wire burst: 16 CONSECUTIVE wire bytes w[p..p+15] in the middle
// of the stream (p = 7*255+32, spans a row boundary). Each of the 16 affected
// codewords gets exactly one corrupted byte -> all decode to their originals.
{
  const blocks = distinctBlocks(16);
  const w = wire(blocks, 16);
  const p = 7 * 255 + 32;
  for (let i = 0; i < 16; i++) w[p + i] ^= 0xa5;
  const out = rs.deinterleave(w, 16, N);
  let ok = out.length === 16;
  let affected = 0;
  for (let k = 0; ok && k < 16; k++) {
    const diff = out[k].filter((b, i) => b !== blocks[k][i]).length;
    if (diff > 0) affected++;
    ok = diff <= 1;
    const dec = rs.decode(out[k]);
    ok = ok && dec !== null && bytesEqual(dec, blocks[k].slice(0, K));
  }
  check("16 consecutive wire bytes: every codeword gets <=1 error", ok && affected === 16);
}

// 10. partial group: 3 codewords round-trip. The wire map is row-major at
// full depth (position b*16 + k); with fewer than 16 codewords the remaining
// slots must be zero-padded (encoder contract), and deinterleave recovers the
// real codewords with the padding codewords coming back as zeros.
{
  const blocks = distinctBlocks(3);
  const padded = blocks.concat(new Array(13).fill(new Uint8Array(N)));
  const w = wire(padded, 16);
  const out = rs.deinterleave(w, 16, N);
  let ok = out.length === 16;
  for (let k = 0; ok && k < 16; k++) ok = bytesEqual(out[k], padded[k]);
  check("partial group of 3 codewords (zero-padded) round-trip", ok);
}

// 11. GF tables sanity: table-driven multiply agrees with carry-less
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
    if (rs.gfMul(a, b) !== z) { ok = false; break; }
  }
  check("gfMul matches carry-less multiply + 0x11D", ok);
}

console.log(failures ? `\n${failures} FAILURE(S)` : "\nRS TESTS GREEN");
process.exitCode = failures ? 1 : 0;
