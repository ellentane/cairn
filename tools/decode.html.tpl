<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cairn Audio Decoder</title>
<style>
body{max-width:42em;margin:2em auto;padding:0 1em;font:16px/1.5 system-ui,sans-serif}
pre{background:#f4f4f4;padding:1em;overflow:auto;max-height:20em}
</style>
</head>
<body>
<h1>Cairn Audio Decoder</h1>
<p>Decode a cairn audio recording (wav, m4a, mp3, ogg — file or live microphone) back into the original page.</p>
<label>Audio file: <input type="file" id="file" accept="audio/*"></label>
<button id="mic">Start microphone decode</button>
<button id="transmit">Transmit loaded file</button>
<button id="loop">loop: off</button>
<p id="status"></p>
<h2>Reconstructed page</h2>
<pre id="out"></pre>
<a id="download" hidden>Download decoded page</a>
<script>
/*__CAIRN_DECODER__*/
(function () {
  var status = document.getElementById("status");
  var out = document.getElementById("out");
  var download = document.getElementById("download");
  var lastWav = null;
  var audioCtx = null;
  var loopOn = false;

  function show(text) { status.textContent = text; }

  function errorText(e) {
    if (e instanceof CairnDecoder.errors.SyncNotFound) return "no cairn frame found in the audio (check the recording)";
    if (e instanceof CairnDecoder.errors.RSCorrectionFailed) return "audio too damaged to repair (RS correction failed)";
    if (e instanceof CairnDecoder.errors.CRCError) return "frame integrity check failed";
    if (e instanceof CairnDecoder.errors.WavParseError || e instanceof CairnDecoder.errors.UnsupportedFormat) return "unsupported audio format";
    if (e.name === "NotSupportedError" || e.name === "EncodingError") return "unsupported audio format";
    return "decode failed: " + (e && e.message ? e.message : e);
  }

  // gunzipSync is node-only; the browser inflates via DecompressionStream
  function inflateGzip(bytes) {
    var ds = new DecompressionStream("gzip");
    var stream = new Blob([bytes]).stream().pipeThrough(ds);
    return new Response(stream).arrayBuffer().then(function (ab) { return new Uint8Array(ab); });
  }

  function int16FromFloat32(f32) {
    var s16 = new Int16Array(f32.length);
    for (var i = 0; i < f32.length; i++) {
      var v = f32[i];
      if (v > 1) v = 1; else if (v < -1) v = -1;
      s16[i] = v * 32767;
    }
    return s16;
  }

  function decodeToPage(res) {
    return inflateGzip(res.compressed).then(function (payload) {
      out.textContent = new TextDecoder().decode(payload);
      download.hidden = false;
      download.href = URL.createObjectURL(new Blob([payload], { type: "text/html" }));
      download.download = "decoded.html";
      var statsText = "";
      if (res.stats) {
        var parts = [];
        if (typeof res.stats.syncSnr === "number" && isFinite(res.stats.syncSnr)) {
          parts.push("sync SNR " + res.stats.syncSnr.toFixed(1) + " dB");
        }
        if (Array.isArray(res.stats.rsCorrections)) {
          var n = 0;
          for (var i = 0; i < res.stats.rsCorrections.length; i++) if (res.stats.rsCorrections[i] > 0) n++;
          parts.push(n + " codewords corrected");
        }
        if (parts.length) statsText = ", " + parts.join(", ");
      }
      show("Decoded " + payload.length + " bytes, CRC verified" + statsText + ".");
    }).catch(function () {
      show("decompression failed.");
    });
  }

  // file path: RIFF wav goes straight to the wav parser; any other container
  // (m4a/mp3/ogg/…) is handed to decodeAudioData, which transcodes to
  // channel-0 Float32 at the file's own sample rate — one path for every
  // recorder app, mono or stereo, 8k–192k
  document.getElementById("file").addEventListener("change", function () {
    var f = this.files[0];
    if (!f) return;
    return f.arrayBuffer().then(function (buf) {
      lastWav = buf;
      var bytes = new Uint8Array(buf);
      try {
        if (bytes.length >= 4 && String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]) === "RIFF") {
          return decodeToPage(CairnDecoder.decodeFrame(bytes));
        }
      } catch (e) {
        show(errorText(e));
        return;
      }
      audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
      return audioCtx.decodeAudioData(buf.slice(0)).then(function (abuf) {
        return decodeToPage(CairnDecoder.decodeFrameSamples(int16FromFloat32(abuf.getChannelData(0)), abuf.sampleRate));
      }).catch(function (e) {
        show(errorText(e));
      });
    }).catch(function (e) {
      show(errorText(e));
    });
  });

  // transmit mode: play the loaded file through the speaker; the loop toggle
  // sets BufferSource.loop (the wav carries its own stop tone, so looping
  // replays the whole transmission)
  document.getElementById("transmit").addEventListener("click", function () {
    if (!lastWav) { show("Load an audio file first."); return; }
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
    audioCtx.decodeAudioData(lastWav.slice(0), function (buf) {
      var src = audioCtx.createBufferSource();
      src.buffer = buf;
      src.loop = loopOn;
      src.connect(audioCtx.destination);
      src.start(0);
      show("Transmitting " + Math.round(buf.duration) + "s of audio" + (loopOn ? " (looping)…" : "…"));
    }, function () { show("Audio decode failed."); });
  });

  document.getElementById("loop").addEventListener("click", function () {
    loopOn = !loopOn;
    this.textContent = loopOn ? "loop: on" : "loop: off";
  });

  // mic path (best-effort): stream samples through the same demodulator
  var micState = null;
  document.getElementById("mic").addEventListener("click", function () {
    if (micState) { micState.analyser = null; micState = null; show("Microphone stopped."); return; }
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      show("getUserMedia not available.");
      return;
    }
    navigator.mediaDevices.getUserMedia({ audio: true }).then(function (stream) {
      audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
      var src = audioCtx.createMediaStreamSource(stream);
      var analyser = audioCtx.createAnalyser();
      analyser.fftSize = 2048;
      src.connect(analyser);
      micState = { analyser: analyser, stream: stream, buffer: [], collecting: false };
      show("Listening… (decoding is best-effort on live audio)");
      var timer = setInterval(function () {
        if (!micState) { clearInterval(timer); return; }
        var data = new Float32Array(analyser.fftSize);
        analyser.getFloatTimeDomainData(data);
        // append samples; demod in 8-sample bit windows when a stable block exists
        var s16 = new Int16Array(data.length);
        for (var i = 0; i < data.length; i++) s16[i] = Math.max(-1, Math.min(1, data[i])) * 32767;
        micState.buffer.push(s16);
        if (micState.buffer.length >= 64 && !micState.collecting) {
          micState.collecting = true;
          setTimeout(function () {
            var flat = new Int16Array(micState.buffer.length * 2048);
            var k = 0;
            for (var j = 0; j < micState.buffer.length; j++) { flat.set(micState.buffer[j], k); k += micState.buffer[j].length; }
            var bits = [];
            var S = 8;
            for (var b = 0; b + S <= flat.length; b += S) {
              var m = 0, s = 0;
              for (var t = b; t < b + S; t++) {
                m += flat[t] * Math.sin(2 * Math.PI * 1200 * t / 19200);
                s += flat[t] * Math.sin(2 * Math.PI * 2400 * t / 19200);
              }
              bits.push(Math.abs(m) > Math.abs(s) ? 1 : 0);
            }
            var bytes = [];
            for (var bb = 0; bb + 8 <= bits.length; bb += 8) {
              var v = 0;
              for (var kk = 0; kk < 8; kk++) v = (v << 1) | bits[bb + kk];
              bytes.push(v);
            }
            // frame parse (shared logic; a future refactor can reuse CairnDecoder internals)
            try {
              var u8 = Uint8Array.from(bytes);
              var payload = CairnDecoder.decodeWavBytes(
                // wrap: build a minimal wav header around the captured samples
                (function () {
                  var header = new Uint8Array(44);
                  var dv = new DataView(header.buffer);
                  header.set([0x52,0x49,0x46,0x46], 0);
                  dv.setUint32(4, 36 + flat.length * 2, true);
                  header.set([0x57,0x41,0x56,0x45,0x66,0x6d,0x74,0x20], 8);
                  dv.setUint32(16, 16, true);
                  dv.setUint16(20, 1, true); dv.setUint16(22, 1, true);
                  dv.setUint32(24, 19200, true); dv.setUint32(28, 38400, true);
                  dv.setUint16(32, 2, true); dv.setUint16(34, 16, true);
                  header.set([0x64,0x61,0x74,0x61], 36);
                  dv.setUint32(40, flat.length * 2, true);
                  var all = new Uint8Array(44 + flat.length * 2);
                  all.set(header);
                  all.set(new Uint8Array(flat.buffer), 44);
                  return all;
                })()
              );
              out.textContent = new TextDecoder().decode(payload);
              show("Microphone decode succeeded: " + payload.length + " bytes.");
            } catch (e) {
              show("Mic decode in progress… (" + e.message + ")");
            }
            micState.collecting = false;
          }, 1500);
        }
      }, 200);
    }).catch(function () { show("Microphone permission denied."); });
  });
})();
</script>
</body>
</html>
