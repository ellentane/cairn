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
  function demodIQAt(samples, cfg, t0) {
    const { sr, spb, tones } = cfg;
    const normalize = cfg.normalize || null;
    const out = [];
    let t = t0;
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
        const nk = normalize ? normalize[k] : 1;
        mags[k] = Math.hypot(I, Q) / (nk > 0 ? nk : 1);
      }
      let best = 0;
      for (let k = 1; k < tones.length; k++) if (mags[k] > mags[best]) best = k;
      out.push(best === 0 ? 1 : 0);
      t += spb;
    }
    return out;
  }

  function demodIQ(samples, cfg) {
    return demodIQAt(samples, cfg, 0);
  }

  // ---- frame-v2 decode (audio relay v2) ----
  // Link profiles mirror LINK_PROFILES in src/audio.zig and
  // tests/link_profiles.json; SYNC_WORD/PREAMBLE_BYTES mirror the same tables.
  // Wire layout: go cue (400 Hz) | preamble 0xAA x96 | sync word (32 bits
  // MSB-first) | data bits | stop tone (800 Hz). Data region: [profile u8]
  // [compressed_len u32le][gzip payload][crc32 u32le over the region],
  // zero-padded to a PAD_GROUP (3568) multiple, RS(255,223) per 223-byte
  // block, interleaved depth-16 row-major. Bits are MSB first; bit 1 ->
  // tone_low (mark), bit 0 -> tone_high (space), per the v1 convention.
  const ENCODER_RATE = 19200;
  const LINK_PROFILES = [
    { name: "clean", tone_low: 1200, tone_high: 2400, samples_per_bit: 8 },
    { name: "radio", tone_low: 1200, tone_high: 2000, samples_per_bit: 12 },
  ];
  const SYNC_WORD = 0xD3A94E57;
  const SYNC_TOLERANCE = 8; // accept a sync match with up to 8 bit errors
  const PREAMBLE_BYTES = 96;
  const V2_GROUP_LEN = 16 * 255; // wire bytes per interleave group (depth x RS block)

  class WavParseError extends Error { constructor(m) { super(m); this.name = "WavParseError"; } }
  class UnsupportedFormat extends Error { constructor(m) { super(m); this.name = "UnsupportedFormat"; } }
  class SyncNotFound extends Error { constructor(m) { super(m); this.name = "SyncNotFound"; } }
  class RSCorrectionFailed extends Error { constructor(m) { super(m); this.name = "RSCorrectionFailed"; } }
  class CRCError extends Error { constructor(m) { super(m); this.name = "CRCError"; } }

  function parseWav(wavBytes) {
    if (String.fromCharCode(wavBytes[0], wavBytes[1], wavBytes[2], wavBytes[3]) !== "RIFF") {
      throw new WavParseError("not a RIFF wav");
    }
    const view = new DataView(wavBytes.buffer, wavBytes.byteOffset, wavBytes.byteLength);
    let off = 12, dataOff = -1, dataLen = 0, sr = 0, channels = 1, formatTag = 1, bits = 16;
    while (off + 8 <= wavBytes.length) {
      const id = String.fromCharCode(wavBytes[off], wavBytes[off + 1], wavBytes[off + 2], wavBytes[off + 3]);
      const len = view.getUint32(off + 4, true);
      if (id === "fmt " && len >= 16) {
        formatTag = view.getUint16(off + 8, true);
        channels = view.getUint16(off + 10, true);
        sr = view.getUint32(off + 12, true);
        bits = view.getUint16(off + 22, true);
      } else if (id === "data") {
        dataOff = off + 8;
        dataLen = len;
        break;
      }
      off += 8 + len;
    }
    if (dataOff < 0) throw new WavParseError("no data chunk");
    if (dataOff + dataLen > wavBytes.length) dataLen = wavBytes.length - dataOff;
    if (sr <= 0) throw new WavParseError("fmt chunk missing sample rate");
    // Format handling: PCM (tag 1) in 8 or 16 bits decodes; float (tag 3) and
    // other encodings/depths are rejected with a classified error rather than
    // converted — phone memo apps record PCM, and the browser path (Task 8)
    // transcodes everything else via decodeAudioData before decodeFrame.
    if (formatTag !== 1) {
      throw new UnsupportedFormat(`unsupported format tag ${formatTag} (PCM expected)`);
    }
    if (bits !== 8 && bits !== 16) {
      throw new UnsupportedFormat(`unsupported bit depth ${bits} (8/16-bit PCM expected)`);
    }
    // keep channel 0 of an interleaved stream (strided reads are parity-safe
    // regardless of data chunk offset); 8-bit unsigned maps to 16-bit signed
    const bytesPerSample = bits === 8 ? 1 : 2;
    const n = Math.floor(Math.floor(dataLen / bytesPerSample) / channels);
    const samples = new Int16Array(n);
    if (bits === 8) {
      for (let i = 0; i < n; i++) samples[i] = ((wavBytes[dataOff + i * channels] & 0xff) - 128) << 8;
    } else if (dataOff % 2 === 0 && channels === 1) {
      samples.set(new Int16Array(wavBytes.buffer, wavBytes.byteOffset + dataOff, n));
    } else {
      for (let i = 0; i < n; i++) samples[i] = view.getInt16(dataOff + i * channels * 2, true);
    }
    return { sr, samples };
  }

  function popcount32(x) {
    x = x - ((x >>> 1) & 0x55555555);
    x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
    x = (x + (x >>> 4)) & 0x0F0F0F0F;
    return (x * 0x01010101) >>> 24;
  }

  // Sync search at 4x oversampling: demodulate the stream on four phase grids
  // (0, spb/4, spb/2, 3*spb/4) and scan each for the sync word. Matches tolerate
  // up to SYNC_TOLERANCE bit errors (echo reflections and clock-offset phase
  // shifts land inside the sync window) and must pass the preamble gate (>=3
  // of the 8 bytes before the sync are 0xAA). The denser grid pins the initial
  // demod phase to within spb/8 samples of the true optimum (which the radio
  // chain shifts off the encoder grid by a few samples); the decoder tries
  // candidates in order (best preamble-correlation score first) and rescans on
  // decode failure.
  function findSyncCandidates(samples, sr, spb, tones) {
    const candidates = [];
    for (const offset of [0, spb / 4, spb / 2, (3 * spb) / 4]) {
      const bits = demodIQAt(samples, { sr, spb, tones }, offset);
      let win = 0;
      for (let p = 0; p < bits.length; p++) {
        win = ((win << 1) | bits[p]) >>> 0;
        if (p < 31) continue;
        if (popcount32(win ^ SYNC_WORD) > SYNC_TOLERANCE) continue;
        const syncStart = p - 31;
        if (syncStart < PREAMBLE_BYTES * 8) continue;
        let aa = 0;
        for (let b = 0; b < 8; b++) {
          let byte = 0;
          for (let k = 0; k < 8; k++) byte = (byte << 1) | bits[syncStart - 64 + b * 8 + k];
          if (byte === 0xAA) aa++;
        }
        if (aa < 3) continue;
        let score = 0;
        for (let j = 0; j < PREAMBLE_BYTES * 8; j++) {
          if (bits[syncStart - PREAMBLE_BYTES * 8 + j] === (j % 2 === 0 ? 1 : 0)) score++;
        }
        candidates.push({ offset, syncStart, score });
      }
    }
    candidates.sort((a, b) => b.score - a.score);
    return candidates.slice(0, 8);
  }

  // Learn per-tone amplitude scalars from the preamble (0xAA = 10101010
  // alternates mark/space, so both tones are present) and the sync SNR: the
  // mean ratio of winning-tone to losing-tone correlation across the preamble,
  // in dB. Returns null if a scalar is unusable.
  function learnToneScales(samples, sr, spb, tones, offset, syncStart) {
    const markBits = [], spaceBits = [];
    for (let j = 0; j < PREAMBLE_BYTES * 8; j++) {
      const t = offset + (syncStart - PREAMBLE_BYTES * 8 + j) * spb;
      if (t + spb > samples.length) break;
      let mI = 0, mQ = 0, sI = 0, sQ = 0;
      for (let s = 0; s < spb; s++) {
        const tt = Math.floor(t + s);
        mI += samples[tt] * Math.cos(2 * Math.PI * tones[0] * tt / sr);
        mQ += samples[tt] * Math.sin(2 * Math.PI * tones[0] * tt / sr);
        sI += samples[tt] * Math.cos(2 * Math.PI * tones[1] * tt / sr);
        sQ += samples[tt] * Math.sin(2 * Math.PI * tones[1] * tt / sr);
      }
      const mm = Math.hypot(mI, mQ), sm = Math.hypot(sI, sQ);
      (j % 2 === 0 ? markBits : spaceBits).push([mm, sm]);
    }
    if (markBits.length === 0 || spaceBits.length === 0) return null;
    const mean = (arr, k) => arr.reduce((a, b) => a + b[k], 0) / arr.length;
    const markM = mean(markBits, 0), spaceM = mean(spaceBits, 1);
    if (markM <= 0 || spaceM <= 0) return null;
    const rMark = mean(markBits, 0) / Math.max(mean(markBits, 1), 1);
    const rSpace = mean(spaceBits, 1) / Math.max(mean(spaceBits, 0), 1);
    const syncSnr = 10 * Math.log10((rMark + rSpace) / 2);
    return { mark: markM, space: spaceM, syncSnr };
  }

  // Interpolated single-tone complex correlation at an arbitrary (fractional)
  // window start. Returns {I, Q, mag} (mag normalized by the per-tone scalar).
  // Linear sample interpolation keeps the complex correlation smooth at any
  // phase — its PHASE advances at the tone frequency as the window slides,
  // which is what the timing tracker measures.
  function winCorrC(samples, sr, f, t, spb, normalize, k) {
    let I = 0, Q = 0;
    for (let s = 0; s < spb; s++) {
      const p = t + s;
      const i0 = Math.floor(p), fr = p - i0;
      const x0 = i0 >= 0 && i0 < samples.length ? samples[i0] : 0;
      const x1 = i0 + 1 < samples.length ? samples[i0 + 1] : 0;
      const xv = x0 + (x1 - x0) * fr;
      I += xv * Math.cos(2 * Math.PI * f * p / sr);
      Q += xv * Math.sin(2 * Math.PI * f * p / sr);
    }
    const nk = normalize[k];
    return { I, Q, mag: Math.hypot(I, Q) / (nk > 0 ? nk : 1) };
  }

  const ANCHOR_BITS = 512;      // re-anchor the sampling phase every N bits
  const PROBE_OFFSETS = [-2, -1, 0, 1, 2]; // candidate phase corrections (samples)
  const PROBE_BITS = 128;       // probe window length in bits

  // Measure the best integer-sample phase correction at time t, decision-
  // directed: take the per-bit tone decisions at the current phase, then for
  // each candidate offset sum the correlation of the DECIDED tone over the
  // probe window. Summing the decided tone (not max of both) makes the metric
  // monotonic in the phase error — the max() form cancels at bit boundaries
  // because the winning tone switches, which is why a magnitude-max probe is
  // blind on the radio chain (measured <1% over +-4 samples vs ~0.5-1% per
  // sample for the decision-directed form). Runs every ANCHOR_BITS bits so the
  // sampling phase tracks ~100 ppm recorder clock drift.
  function probePhase(samples, sr, spb, tones, normalize, t) {
    const dec = [];
    for (let b = 0; b < PROBE_BITS; b++) {
      const c0 = winCorrC(samples, sr, tones[0], t + b * spb, spb, normalize, 0);
      const c1 = winCorrC(samples, sr, tones[1], t + b * spb, spb, normalize, 1);
      dec.push(c0.mag >= c1.mag ? 0 : 1);
    }
    let best = 0, bestSum = -1, zeroSum = -1;
    for (const off of PROBE_OFFSETS) {
      let sum = 0;
      for (let b = 0; b < PROBE_BITS; b++) {
        const c = winCorrC(samples, sr, tones[dec[b]], t + off + b * spb, spb, normalize, dec[b]);
        sum += c.mag;
      }
      if (off === 0) zeroSum = sum;
      if (sum > bestSum) { bestSum = sum; best = off; }
    }
    // only correct when the best offset beats the current phase by a real
    // margin: with tones that are sub-harmonics of the bit rate (the clean
    // profile's 0.5/1.0 cycles per bit) the correlation is flat across window
    // shifts (measured < 0.1%), and blind corrections would walk the phase
    // away. The radio profile's misalignment signal is ~1% per sample, so
    // 0.3% separates the two.
    if (best !== 0 && bestSum < zeroSum * 1.003) return 0;
    return best;
  }

  // Demodulate `bitCount` data bits starting at phaseState.phase, with
  // per-tone normalization and periodic phase re-anchoring (probePhase every
  // ANCHOR_BITS bits). Keeps ~100 ppm recorder clock drift from accumulating
  // over a long frame; decisions are robust to a residual phase error of a few
  // samples (the bit window is spb samples wide).
  function demodTracked(samples, sr, spb, tones, phaseState, bitCount, normalize) {
    const bits = [];
    let t = phaseState.phase;
    for (let d = 0; d < bitCount; d++) {
      if (d > 0 && d % ANCHOR_BITS === 0) t += probePhase(samples, sr, spb, tones, normalize, t);
      const c0 = winCorrC(samples, sr, tones[0], t, spb, normalize, 0);
      const c1 = winCorrC(samples, sr, tones[1], t, spb, normalize, 1);
      bits.push(c0.mag >= c1.mag ? 1 : 0);
      t += spb;
    }
    phaseState.phase = t;
    return bits;
  }

  // Demodulate the data region group by group (the phase accumulator persists
  // across groups so drift keeps tracking), deinterleave, RS-decode each
  // codeword (collecting correction counts), rebuild the data region, and
  // verify the crc32 over [profile][compressed_len][gzip payload] before
  // trimming to compressed_len. Throws RSCorrectionFailed / CRCError.
  function decodeRegionTracked(samples, sr, spb, tones, t0, normalize, stats) {
    const phaseState = { phase: t0 };
    let region = new Uint8Array(0);
    for (;;) {
      if (phaseState.phase + spb > samples.length) throw new CRCError("no region crc match");
      const bits = demodTracked(samples, sr, spb, tones, phaseState, V2_GROUP_LEN * 8, normalize);
      const wireBytes = bitsToBytes(bits);
      const group = rs.deinterleave(wireBytes, 16, 255);
      for (const cw of group) {
        const errs = [];
        const dec = rs.decode(cw, errs);
        if (dec === null) throw new RSCorrectionFailed("uncorrectable codeword");
        stats.rsCorrections.push(errs.length ? errs[0] : 0);
        const next = new Uint8Array(region.length + dec.length);
        next.set(region);
        next.set(dec, region.length);
        region = next;
      }
      if (region.length >= 9) {
        const len = (region[1] | (region[2] << 8) | (region[3] << 16) | (region[4] << 24)) >>> 0;
        if (5 + len + 4 <= region.length) {
          const got = (region[5 + len] | (region[6 + len] << 8) | (region[7 + len] << 16) | (region[8 + len] << 24)) >>> 0;
          if (crc32(region.subarray(0, 5 + len)) === got) return region.slice(5, 5 + len);
        }
      }
    }
  }

  // Find the frame on its own: try each link profile, scanning the sample
  // stream for the sync word; for each sync candidate (in score order, max 8)
  // learn the tone scalars, demodulate with drift tracking, and decode the
  // region. Returns the recovered compressed payload and decode stats.
  function decodeFrame(wavBytes) {
    const { sr, samples } = parseWav(wavBytes);
    let lastErr = null;
    for (const profile of LINK_PROFILES) {
      const spb = sr / (ENCODER_RATE / profile.samples_per_bit);
      const tones = [profile.tone_low, profile.tone_high];
      for (const cand of findSyncCandidates(samples, sr, spb, tones)) {
        const scales = learnToneScales(samples, sr, spb, tones, cand.offset, cand.syncStart);
        if (scales === null) continue;
        const stats = { syncSnr: scales.syncSnr, rsCorrections: [] };
        const t0 = cand.offset + (cand.syncStart + 32) * spb;
        try {
          const compressed = decodeRegionTracked(samples, sr, spb, tones, t0, scales, stats);
          return { profile: profile.name, compressed, stats };
        } catch (e) {
          lastErr = e;
        }
      }
    }
    if (lastErr) throw lastErr;
    throw new SyncNotFound("no frame found");
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
  // input is never silently corrupted. If `errOut` (an array) is given, the
  // number of corrected symbols is pushed onto it (0 for a clean codeword).
  function rsDecode(cw, errOut) {
    const synd = rsSyndromes(cw);
    if (synd.every(s => s === 0)) {
      if (errOut) errOut.push(0);
      return cw.slice(0, RS_K);
    }
    const errLoc = rsFindErrorLocator(synd);
    if (errLoc === null) return null;
    const errPos = rsFindErrors(errLoc.slice().reverse());
    if (errPos === null) return null;
    const msg = rsCorrectErrata(cw.slice(), synd, errPos);
    if (msg === null) return null;
    const post = rsSyndromes(msg);
    if (!post.every(s => s === 0)) return null;
    if (errOut) errOut.push(errPos.length);
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

  const rs = { encode: rsEncode, decode: rsDecode, deinterleave, gfMul, N: RS_N, K: RS_K, NSYM: RS_NSYM };

  const api = {
    decodeWavBytes, crc32, demodIQ, gunzipSync, decodeFrame,
    errors: { WavParseError, UnsupportedFormat, SyncNotFound, RSCorrectionFailed, CRCError },
    rs,
  };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.CairnDecoder = api;
})(typeof self !== "undefined" ? self : this);
