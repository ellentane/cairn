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
<p>Decode a cairn <code>.wav</code> (file or live microphone) back into the original page.</p>
<label>WAV file: <input type="file" id="file" accept=".wav,audio/wav"></label>
<button id="mic">Start microphone decode</button>
<button id="transmit">Transmit loaded WAV</button>
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

  function show(text) { status.textContent = text; }

  // file path (exact)
  document.getElementById("file").addEventListener("change", function () {
    var f = this.files[0];
    if (!f) return;
    f.arrayBuffer().then(function (buf) {
      lastWav = buf;
      var bytes = new Uint8Array(buf);
      try {
        var payload = CairnDecoder.decodeWavBytes(bytes);
        var text = new TextDecoder().decode(payload);
        out.textContent = text;
        download.hidden = false;
        download.href = URL.createObjectURL(new Blob([payload], { type: "text/html" }));
        download.download = "decoded.html";
        show("Decoded " + payload.length + " bytes, CRC verified.");
      } catch (e) { show("Decode failed: " + e.message); }
    });
  });

  // transmit mode: play the loaded wav through the speaker
  document.getElementById("transmit").addEventListener("click", function () {
    if (!lastWav) { show("Load a WAV file first."); return; }
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
    audioCtx.decodeAudioData(lastWav.slice(0), function (buf) {
      var src = audioCtx.createBufferSource();
      src.buffer = buf;
      src.connect(audioCtx.destination);
      src.start(0);
      show("Transmitting " + Math.round(buf.duration) + "s of audio…");
    }, function () { show("Audio decode failed."); });
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
            var flat = new Int16Array(64 * 2048);
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
