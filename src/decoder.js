"use strict";
// Cairn FSK audio decoder (v1.0) — shared by decode.html and node tests.
(function (root) {
  const SAMPLES_PER_BIT = 8;
  const MARK_HZ = 1200;
  const SPACE_HZ = 2400;
  const SAMPLE_RATE = 19200;
  const PREAMBLE_LEN = 64;

  function crc32(data) {
    let crc = 0xFFFFFFFF;
    for (const byte of data) {
      crc ^= byte;
      for (let i = 0; i < 8; i++) {
        const mask = (crc & 1) ? 0xEDB88320 : 0;
        crc = (crc >>> 1) ^ mask;
      }
    }
    return (~crc) >>> 0;
  }

  function demodulate(samples) {
    const bits = [];
    for (let i = 0; i + SAMPLES_PER_BIT <= samples.length; i += SAMPLES_PER_BIT) {
      let m = 0, s = 0;
      for (let k = 0; k < SAMPLES_PER_BIT; k++) {
        const t = i + k;
        m += samples[t] * Math.sin(2 * Math.PI * MARK_HZ * t / SAMPLE_RATE);
        s += samples[t] * Math.sin(2 * Math.PI * SPACE_HZ * t / SAMPLE_RATE);
      }
      bits.push(Math.abs(m) > Math.abs(s) ? 1 : 0); // phase-agnostic decision
    }
    return bits;
  }

  function bitsToBytes(bits) {
    const bytes = [];
    for (let i = 0; i + 8 <= bits.length; i += 8) {
      let b = 0;
      for (let k = 0; k < 8; k++) b = (b << 1) | bits[i + k];
      bytes.push(b);
    }
    return Uint8Array.from(bytes);
  }

  function decodeWavBytes(wavBytes) {
    if (String.fromCharCode(wavBytes[0], wavBytes[1], wavBytes[2], wavBytes[3]) !== "RIFF") {
      throw new Error("not a RIFF wav");
    }
    const view = new DataView(wavBytes.buffer, wavBytes.byteOffset, wavBytes.byteLength);
    let off = 12;
    let dataOff = -1, dataLen = 0;
    while (off + 8 <= wavBytes.length) {
      const id = String.fromCharCode(wavBytes[off], wavBytes[off + 1], wavBytes[off + 2], wavBytes[off + 3]);
      const len = view.getUint32(off + 4, true);
      if (id === "data") { dataOff = off + 8; dataLen = len; break; }
      off += 8 + len;
    }
    if (dataOff < 0) throw new Error("no data chunk");
    // clamp a lying data chunk length: real wavs may carry trailing chunks,
    // so an over-claiming length just yields fewer samples (frame parse
    // reports "frame truncated" / CRC mismatch); never allocate past the file
    if (dataOff + dataLen > wavBytes.length) dataLen = wavBytes.length - dataOff;
    let samples;
    if (dataOff % 2 === 0) {
      samples = new Int16Array(wavBytes.buffer, wavBytes.byteOffset + dataOff, Math.floor(dataLen / 2));
    } else {
      const raw = new Int16Array(Math.floor(dataLen / 2));
      for (let i = 0; i < raw.length; i++) raw[i] = view.getInt16(dataOff + i * 2, true);
      samples = raw;
    }
    const bytes = bitsToBytes(demodulate(samples));
    const pre = PREAMBLE_LEN;
    if (pre + 4 + 4 > bytes.length) throw new Error("frame truncated");
    const len = (bytes[pre] | (bytes[pre + 1] << 8) | (bytes[pre + 2] << 16) | (bytes[pre + 3] << 24)) >>> 0;
    if (pre + 4 + len + 4 > bytes.length) throw new Error("frame truncated");
    const payload = bytes.slice(pre + 4, pre + 4 + len);
    const crc = (bytes[pre + 4 + len] | (bytes[pre + 5 + len] << 8) |
      (bytes[pre + 6 + len] << 16) | (bytes[pre + 7 + len] << 24)) >>> 0;
    if (crc32(payload) !== crc) throw new Error("crc mismatch");
    return payload;
  }

  // Quadrature I/Q correlation demod (v2): for each bit window of `spb`
  // (fractional allowed — the window start accumulates exactly `spb` per bit,
  // so integer spb is exact), correlate against each tone with sin AND cos
  // oscillators and take |c| = sqrt(I^2 + Q^2). Decision: the tone with the
  // largest magnitude. Amplitude-invariant (AGC-proof); phase-invariant
  // (radio chains inject arbitrary carrier phase). Returns bit values:
  // tones[0] (mark) = 1, tones[1] (space) = 0, per the v1 convention.
  function demodIQ(samples, cfg) {
    const { sr, spb, tones } = cfg;
    const out = [];
    let t = 0;
    while (t + spb <= samples.length + 1e-9) {
      const mags = tones.map(() => 0);
      for (let k = 0; k < tones.length; k++) {
        let I = 0, Q = 0;
        const f = tones[k];
        const win = Math.min(spb, samples.length - t);
        for (let s = 0; s < win; s++) {
          const tt = Math.floor(t + s);
          I += samples[tt] * Math.cos(2 * Math.PI * f * tt / sr);
          Q += samples[tt] * Math.sin(2 * Math.PI * f * tt / sr);
        }
        mags[k] = Math.hypot(I, Q);
      }
      let best = 0;
      for (let k = 1; k < tones.length; k++) if (mags[k] > mags[best]) best = k;
      out.push(best === 0 ? 1 : 0);
      t += spb;
    }
    return out;
  }

  // Reed-Solomon (255,223) codec (v2 audio relay). Parameterization matches
  // python reedsolo: GF(2^8) prim 0x11D, alpha=2, 32 roots alpha^0..alpha^31
  // (fcr=0), systematic encoding (data || parity), polynomial bytes
  // highest-degree-first (byte 0 = coefficient of x^254). Corrects up to 16
  // byte-errors per 255-byte codeword; >16 errors -> null (uncorrectable).
  const RS_N = 255;
  const RS_K = 223;
  const RS_NSYM = 32;

  const gfExp = new Uint8Array(512);
  const gfLog = new Uint8Array(256);
  {
    let x = 1;
    for (let i = 0; i < 255; i++) {
      gfExp[i] = x;
      gfLog[x] = i;
      x <<= 1;
      if (x & 0x100) x ^= 0x11d;
    }
    for (let i = 255; i < 512; i++) gfExp[i] = gfExp[i - 255];
  }

  function gfMul(a, b) {
    if (a === 0 || b === 0) return 0;
    return gfExp[gfLog[a] + gfLog[b]];
  }

  function gfInv(a) {
    return gfExp[255 - gfLog[a]];
  }

  function gfPow(a, p) {
    return gfExp[((gfLog[a] * p) % 255 + 255) % 255];
  }

  // polynomial helpers (highest-degree-first)
  function polyMul(p, q) {
    const r = new Array(p.length + q.length - 1).fill(0);
    for (let i = 0; i < p.length; i++)
      for (let j = 0; j < q.length; j++)
        r[i + j] ^= gfMul(p[i], q[j]);
    return r;
  }

  function polyScale(p, s) {
    const r = new Array(p.length);
    for (let i = 0; i < p.length; i++) r[i] = gfMul(p[i], s);
    return r;
  }

  function polyAdd(p, q) {
    const n = Math.max(p.length, q.length);
    const r = new Array(n).fill(0);
    for (let i = 0; i < p.length; i++) r[i + n - p.length] ^= p[i];
    for (let i = 0; i < q.length; i++) r[i + n - q.length] ^= q[i];
    return r;
  }

  function polyEval(p, v) {
    let y = p[0];
    for (let i = 1; i < p.length; i++) y = gfMul(y, v) ^ p[i];
    return y;
  }

  // generator polynomial g(x) = prod (x - alpha^i), i in 0..31
  let rsGen = [1];
  for (let i = 0; i < RS_NSYM; i++) rsGen = polyMul(rsGen, [1, gfPow(2, i)]);

  // systematic encoder: data(223) -> codeword(255) = data || parity.
  // Synthetic division, then restore the message region (division clobbers it).
  function rsEncode(data) {
    const out = new Uint8Array(RS_N);
    out.set(data, 0);
    for (let i = 0; i < RS_K; i++) {
      const coef = out[i];
      if (coef !== 0) {
        for (let j = 1; j <= RS_NSYM; j++) out[i + j] ^= gfMul(rsGen[j], coef);
      }
    }
    out.set(data, 0);
    return out;
  }

  function rsSyndromes(cw) {
    const synd = [0];
    for (let i = 0; i < RS_NSYM; i++) synd.push(polyEval(cw, gfPow(2, i)));
    return synd;
  }

  function rsFindErrorLocator(synd) {
    let errLoc = [1];
    let oldLoc = [1];
    const syndShift = synd.length - RS_NSYM;
    for (let i = 0; i < RS_NSYM; i++) {
      const K = i + syndShift;
      let delta = synd[K];
      for (let j = 1; j < errLoc.length; j++) {
        delta ^= gfMul(errLoc[errLoc.length - 1 - j], synd[K - j]);
      }
      oldLoc = oldLoc.concat([0]);
      if (delta !== 0) {
        if (oldLoc.length > errLoc.length) {
          const newLoc = polyScale(oldLoc, delta);
          oldLoc = polyScale(errLoc, gfInv(delta));
          errLoc = newLoc;
        }
        errLoc = polyAdd(errLoc, polyScale(oldLoc, delta));
      }
    }
    while (errLoc.length > 0 && errLoc[0] === 0) errLoc.shift();
    const errs = errLoc.length - 1;
    if (errs * 2 > RS_NSYM) return null;
    return errLoc;
  }

  function rsFindErrors(errLoc) {
    const errPos = [];
    for (let i = 0; i < RS_N; i++) {
      if (polyEval(errLoc, gfPow(2, i)) === 0) errPos.push(RS_N - 1 - i);
    }
    if (errPos.length !== errLoc.length - 1) return null;
    return errPos;
  }

  // Omega(x) = [Synd(x) * err_loc(x)] mod x^(nsym+1)
  function rsFindErrorEvaluator(synd, errLoc, nsym) {
    const prod = polyMul(synd, errLoc);
    const keep = prod.slice(prod.length - (nsym + 1));
    return keep;
  }

  function rsCorrectErrata(msg, synd, errPos) {
    const coefPos = errPos.map(p => msg.length - 1 - p);
    let errLoc = [1];
    for (const cp of coefPos) errLoc = polyMul(errLoc, [gfPow(2, cp), 1]); // alpha^cp * x + 1
    const errEval = rsFindErrorEvaluator(synd.slice().reverse(), errLoc, errLoc.length - 1).reverse();
    const X = [];
    for (const cp of coefPos) {
      const l = RS_N - cp;
      X.push(gfPow(2, -l));
    }
    for (let i = 0; i < X.length; i++) {
      const Xi = X[i];
      const XiInv = gfInv(Xi);
      let errLocPrime = 1;
      for (let j = 0; j < X.length; j++) {
        if (j !== i) errLocPrime = gfMul(errLocPrime, 1 ^ gfMul(XiInv, X[j]));
      }
      if (errLocPrime === 0) return null;
      let y = polyEval(errEval.slice().reverse(), XiInv);
      y = gfMul(gfPow(Xi, 1), y);
      msg[errPos[i]] ^= gfMul(y, gfInv(errLocPrime));
    }
    return msg;
  }

  // codeword(255) -> data(223) | null. null = uncorrectable (>16 errors); the
  // input is never silently corrupted.
  function rsDecode(cw) {
    const synd = rsSyndromes(cw);
    if (synd.every(s => s === 0)) return cw.slice(0, RS_K);
    const errLoc = rsFindErrorLocator(synd);
    if (errLoc === null) return null;
    const errPos = rsFindErrors(errLoc.slice().reverse());
    if (errPos === null) return null;
    const msg = rsCorrectErrata(cw.slice(), synd, errPos);
    if (msg === null) return null;
    const post = rsSyndromes(msg);
    if (!post.every(s => s === 0)) return null;
    return msg.slice(0, RS_K);
  }

  // Row-major inverse of the wire map: wire position b*depth + k -> codeword
  // k, byte index b. blocks = bytes.length / blockLen. Partial groups (fewer
  // than `depth` codewords) round-trip only if the encoder zero-pads them to a
  // full depth*blockLen wire (the wire map reserves depth slots per row); the
  // padding codewords come back as zero codewords and decode to 223 zero
  // bytes.
  function deinterleave(bytes, depth, blockLen) {
    if (bytes.length % blockLen !== 0) throw new Error("wire length not a multiple of blockLen");
    const count = bytes.length / blockLen;
    const out = [];
    for (let k = 0; k < count; k++) {
      const cw = new Uint8Array(blockLen);
      for (let b = 0; b < blockLen; b++) cw[b] = bytes[b * depth + k];
      out.push(cw);
    }
    return out;
  }

  // v2 gzip inflate seam (node): zlib.gunzipSync — NOT inflateSync, which
  // rejects the gzip container header. The browser path arrives with
  // decode.html (Task 8) via DecompressionStream('gzip'), which is
  // async-only — hence the split: sync decodeFrame + this sync inflate seam
  // in node, async inflate in the browser.
  let _gunzip = null;
  if (typeof require !== "undefined") {
    const zlib = require("zlib");
    _gunzip = (bytes) => new Uint8Array(zlib.gunzipSync(Buffer.from(bytes)));
  }
  function gunzipSync(bytes) {
    if (_gunzip === null) throw new Error("gunzipSync is node-only; decode.html uses DecompressionStream");
    return _gunzip(bytes);
  }

  const api = {
    decodeWavBytes, crc32, demodIQ, gunzipSync,
    rs: { encode: rsEncode, decode: rsDecode, deinterleave, gfMul, N: RS_N, K: RS_K, NSYM: RS_NSYM },
  };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.CairnDecoder = api;
})(typeof self !== "undefined" ? self : this);
