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

  function showDecoded(payload, stats) {
    out.textContent = new TextDecoder().decode(payload);
    download.hidden = false;
    download.href = URL.createObjectURL(new Blob([payload], { type: "text/html" }));
    download.download = "decoded.html";
    var statsText = "";
    if (stats) {
      var parts = [];
      if (typeof stats.syncSnr === "number" && isFinite(stats.syncSnr)) {
        parts.push("sync SNR " + stats.syncSnr.toFixed(1) + " dB");
      }
      if (Array.isArray(stats.rsCorrections)) {
        var n = 0;
        for (var i = 0; i < stats.rsCorrections.length; i++) if (stats.rsCorrections[i] > 0) n++;
        parts.push(n + " codewords corrected");
      }
      if (parts.length) statsText = ", " + parts.join(", ");
    }
    show("Decoded " + payload.length + " bytes, CRC verified" + statsText + ".");
  }

  function decodeToPage(res) {
    return inflateGzip(res.compressed).then(function (payload) {
      showDecoded(payload, res.stats);
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

  // mic path (v2): gapless capture into an AudioWorklet (ScriptProcessor
  // fallback for old browsers), record-then-decode when the toggle is pressed
  // again. The decoder runs on the context's native sample rate — the frame
  // spb is derived from it, so no resampling and no demod here.
  var mic = null;
  var micChunkLen = 4096;
  var micCapSec = 5 * 60;
  var micWorkletUrl = URL.createObjectURL(new Blob([(
    "class CairnCapture extends AudioWorkletProcessor {" +
    "  constructor() { super(); this.buf = new Float32Array(" + micChunkLen + "); this.n = 0; }" +
    "  process(inputs) {" +
    "    var ch = inputs[0] && inputs[0][0];" +
    "    if (ch) for (var i = 0; i < ch.length; i++) {" +
    "      this.buf[this.n++] = ch[i];" +
    "      if (this.n === this.buf.length) { this.port.postMessage(this.buf); this.n = 0; }" +
    "    }" +
    "    return true;" +
    "  }" +
    "}" +
    "registerProcessor('cairn-capture', CairnCapture);"
  )], { type: "application/javascript" }));

  function micAccumulate(chunk) {
    if (!mic) return;
    mic.chunks.push(chunk);
    mic.total += chunk.length;
    // bound memory at ~5 minutes: drop the oldest chunk(s)
    while (mic.total > mic.cap && mic.chunks.length > 1) mic.total -= mic.chunks.shift().length;
  }

  function micFallback(src) {
    var sp = audioCtx.createScriptProcessor(0, 1, 1);
    sp.onaudioprocess = function (e) { micAccumulate(e.inputBuffer.getChannelData(0).slice()); };
    src.connect(sp);
    sp.connect(audioCtx.destination);
    mic.node = sp;
  }

  function micStart(stream) {
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
    mic = {
      stream: stream, chunks: [], total: 0, rate: audioCtx.sampleRate,
      cap: micCapSec * audioCtx.sampleRate, t0: Date.now(),
    };
    document.getElementById("mic").textContent = "Stop microphone";
    show("Listening… (recording 0.0s) — stop when the transmission ends");
    mic.timer = setInterval(function () {
      if (!mic) { clearInterval(mic.timer); return; }
      show("Listening… (recording " + ((Date.now() - mic.t0) / 1000).toFixed(1) + "s) — stop when the transmission ends");
    }, 500);
    var src = audioCtx.createMediaStreamSource(stream);
    if (audioCtx.audioWorklet && window.AudioWorkletNode) {
      return audioCtx.audioWorklet.addModule(micWorkletUrl).then(function () {
        if (!mic) return;
        var node = new window.AudioWorkletNode(audioCtx, "cairn-capture");
        node.port.onmessage = function (e) { micAccumulate(e.data); };
        src.connect(node);
        node.connect(audioCtx.destination);
        mic.node = node;
      }).catch(function () { if (mic) micFallback(src); });
    }
    micFallback(src);
  }

  function micStop() {
    var m = mic;
    mic = null;
    clearInterval(m.timer);
    document.getElementById("mic").textContent = "Start microphone decode";
    m.stream.getTracks().forEach(function (t) { t.stop(); });
    if (m.node && m.node.disconnect) m.node.disconnect();
    if (m.total === 0) { show("Nothing recorded."); return; }
    var flat = new Float32Array(m.total);
    var off = 0;
    for (var i = 0; i < m.chunks.length; i++) { flat.set(m.chunks[i], off); off += m.chunks[i].length; }
    show("Decoding " + (m.total / m.rate).toFixed(1) + "s of captured audio…");
    var res;
    try {
      res = CairnDecoder.decodeFrameSamples(int16FromFloat32(flat), m.rate);
    } catch (e) {
      show(errorText(e));
      return;
    }
    return inflateGzip(res.compressed).then(function (payload) {
      showDecoded(payload, res.stats);
    }).catch(function () {
      show("decompression failed.");
    });
  }

  document.getElementById("mic").addEventListener("click", function () {
    if (mic) return micStop();
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      show("getUserMedia not available.");
      return;
    }
    return navigator.mediaDevices.getUserMedia({ audio: true }).then(micStart).catch(function () {
      mic = null;
      document.getElementById("mic").textContent = "Start microphone decode";
      show("Microphone permission denied.");
    });
  });
})();
</script>
</body>
</html>
