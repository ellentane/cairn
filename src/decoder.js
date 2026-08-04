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
    const len = bytes[pre] | (bytes[pre + 1] << 8) | (bytes[pre + 2] << 16) | (bytes[pre + 3] << 24);
    if (pre + 4 + len + 4 > bytes.length) throw new Error("frame truncated");
    const payload = bytes.slice(pre + 4, pre + 4 + len);
    const crc = (bytes[pre + 4 + len] | (bytes[pre + 5 + len] << 8) |
      (bytes[pre + 6 + len] << 16) | (bytes[pre + 7 + len] << 24)) >>> 0;
    if (crc32(payload) !== crc) throw new Error("crc mismatch");
    return payload;
  }

  const api = { decodeWavBytes, crc32 };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.CairnDecoder = api;
})(typeof self !== "undefined" ? self : this);
