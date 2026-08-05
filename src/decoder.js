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

  const api = { decodeWavBytes, crc32, demodIQ };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.CairnDecoder = api;
})(typeof self !== "undefined" ? self : this);
