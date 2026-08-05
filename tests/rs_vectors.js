"use strict";
// Pinned test vectors for the Cairn RS(255,223) codec (audio relay v2, task 2).
// Shared by the JS decoder (tests/rs_test.js) and the Zig encoder (src/audio.zig).
//
// Parameterization (matches python reedsolo's reference convention):
//   - GF(2^8), primitive polynomial 0x11D (x^8+x^4+x^3+x^2+1)
//   - primitive element (generator) alpha = 2
//   - 32 parity roots alpha^0 .. alpha^31 (fcr = 0)
//   - systematic encoding: codeword = 223 data bytes || 32 parity bytes
//   - polynomial bytes are highest-degree-first: byte 0 is the coefficient of x^254
//
// Vector 1: data = 223 bytes (i*7+3) & 0xff, parity pinned below (32 bytes).
// Vector 2: corrupted = vector-1 codeword with 8 errors injected at
// errorPositions, each byte flipped with ^ 0x5A.
//
// The pinned parity was produced by the following auditable Python generator
// (hand-rolled GF(256), reedsolo-convention encoder), then cross-validated:
//   - byte-identical to reedsolo.rs_encode_msg(data, 32, fcr=0, generator=2)
//     after reedsolo.init_tables() (prim 0x11D), and
//   - the decode path was fuzz-tested against reedsolo.rs_correct_msg on 200
//     random 1..16-error patterns (all agree).
//
// ---------------------------------------------------------------------------
// Python generator (the exact code that produced `parity`):
//
//   PRIM = 0x11D; NSYM = 32; N = 255; K = N - NSYM
//   exp = [0] * 512; log = [0] * 256
//   x = 1
//   for i in range(255):
//       exp[i] = x; log[x] = i; x <<= 1
//       if x & 0x100: x ^= PRIM
//   for i in range(255, 512): exp[i] = exp[i - 255]
//
//   def gf_mul(a, b):
//       return 0 if (a == 0 or b == 0) else exp[log[a] + log[b]]
//   def gf_pow(a, p): return exp[(log[a] * p) % 255]
//   def poly_mul(p, q):
//       r = [0] * (len(p) + len(q) - 1)
//       for i in range(len(p)):
//           for j in range(len(q)): r[i + j] ^= gf_mul(p[i], q[j])
//       return r
//
//   gen = [1]
//   for i in range(NSYM): gen = poly_mul(gen, [1, gf_pow(2, i)])  # prod (x - alpha^i)
//
//   def rs_encode(msg):
//       out = list(msg) + [0] * NSYM
//       for i in range(len(msg)):
//           coef = out[i]
//           if coef != 0:
//               for j in range(1, len(gen)): out[i + j] ^= gf_mul(gen[j], coef)
//       out[:len(msg)] = msg   # synthetic division clobbers the message region
//       return out             # data || parity
//
//   data = bytes((i * 7 + 3) & 0xFF for i in range(K))
//   cw = rs_encode(data)
//   parity = cw[K:]
// ---------------------------------------------------------------------------

const K = 223; // data bytes
const N = 255; // codeword bytes
const NSYM = 32; // parity bytes

// Vector 1 data: 223 bytes (i*7+3) & 0xff
function dataVector() {
  const d = new Uint8Array(K);
  for (let i = 0; i < K; i++) d[i] = (i * 7 + 3) & 0xff;
  return d;
}

// Pinned parity for vector 1 (auditable via the generator above; byte-identical
// to reedsolo output).
const parity = Uint8Array.from([
  239, 7, 171, 13, 252, 231, 26, 60, 232, 218, 129, 162, 52, 198, 198, 31,
  187, 30, 222, 146, 76, 130, 254, 114, 123, 65, 163, 215, 127, 99, 237, 65,
]);

// Vector 2: error positions injected into the vector-1 codeword (flip ^ 0x5A).
const errorPositions = [10, 50, 90, 130, 170, 210, 215, 220];

// Vector 2: the full 255-byte corrupted codeword, built from the pinned pieces.
function corruptedCodeword() {
  const cw = new Uint8Array(N);
  cw.set(dataVector(), 0);
  cw.set(parity, K);
  for (const p of errorPositions) cw[p] ^= 0x5a;
  return cw;
}

module.exports = { K, N, NSYM, dataVector, parity, errorPositions, corruptedCodeword };
