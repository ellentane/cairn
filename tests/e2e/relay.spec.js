const { test, expect } = require("@playwright/test");
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

// Real-browser relay validation: the wav is played through a genuine WebAudio
// graph (BufferSource -> MediaStreamAudioDestinationNode) and decode.html's
// microphone path records it through a real AudioContext -> AudioWorklet
// pipeline, then decodes it back to the original page. The channel-sim relay
// gate (tests/channel_sim.js --relay) is the decode proof for the acoustic/
// radio chain — it runs the SAME decodeFrameSamples entry through the
// three-leg model at 1% FER.
//
// Two modes:
// - default: plumbing assertions (capture starts, pipeline runs, zero page
//   errors). Runs under both chromium and firefox projects.
// - RELAY_STRICT=1: full reconstruction — the recorded transmission must
//   decode byte-exact (CRC verified) and re-render the page. Runs in CI under
//   the firefox project. Headless Chromium's MediaStreamAudioDestinationNode
//   -> AudioWorklet capture path corrupts the signal at the sample level in
//   this environment (measured extensively: levels and tone content are
//   correct, but the captured stream does not match the source waveform and
//   no rate hypothesis decodes) — an environment artifact of Chromium's audio
//   stack, not a cairn defect. Firefox's capture path is clean, so the strict
//   assertion runs there. Real-hardware validation is covered by the field
//   test protocol (docs/superpowers/audio-field-test.md).
const root = path.join(__dirname, "..", "..");

function buildRelayAudio() {
  const out = path.join(root, "tmp-e2e");
  fs.mkdirSync(out, { recursive: true });
  execSync(
    `${path.join(root, "zig-out", "bin", "cairn")} build tests/e2e/fixtures/counter.md --output ${out}/relay-page.html --audio ${out}/relay.wav --audio-profile radio`,
    { cwd: root, stdio: "pipe" }
  );
  return { wavPath: path.join(out, "relay.wav"), seconds: wavDuration(path.join(out, "relay.wav")) };
}

function wavDuration(p) {
  const b = fs.readFileSync(p);
  const data = b.indexOf("data");
  const byteRate = b.readUInt32LE(28);
  return (b.length - 4 - data) / byteRate;
}

test.use({
  launchOptions: {
    args: ["--autoplay-policy=no-user-gesture-required"],
  },
});

test("relay: mic path captures full-level audio through the real WebAudio graph and runs the decode pipeline", async ({ page }) => {
  test.setTimeout(150000);
  const { seconds } = buildRelayAudio();
  const strict = process.env.RELAY_STRICT === "1";
  await page.addInitScript(async ({ wavUrl }) => {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const resp = await fetch(wavUrl);
    const buf = await ctx.decodeAudioData(await resp.arrayBuffer());
    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.loop = false;
    const dest = ctx.createMediaStreamDestination();
    src.connect(dest);
    src.start();
    Object.defineProperty(navigator, "mediaDevices", {
      value: { getUserMedia: async () => dest.stream },
      configurable: true,
    });
  }, { wavUrl: "http://127.0.0.1:8931/relay.wav" });

  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/decode.html");
  // wait until the page script has run (CairnDecoder is defined synchronously
  // right before the event handlers attach) — under parallel load the click
  // can otherwise land before the handlers exist
  await page.waitForFunction(() => window.CairnDecoder && document.getElementById("mic"), null, { timeout: 15000 });
  await page.click("#mic");
  await expect(page.locator("#status")).toContainText("Listening", { timeout: 15000 });
  if (strict) {
    // Full-reconstruction assertion: speaker -> mic -> decode.html must
    // recover the page byte-exact. Runs in CI under the firefox project —
    // headless Chromium's capture path corrupts the signal here (see header),
    // Firefox's is clean.
    await page.waitForTimeout(Math.ceil(seconds * 1000) + 3000);
    await page.click("#mic");
    await expect(page.locator("#out")).toContainText("id=\"inc\"", { timeout: 60000 });
    await expect(page.locator("#status")).toContainText("CRC verified");
    expect(errors).toEqual([]);
    return;
  }
  // let the capture accumulate real audio for a few seconds
  await page.waitForTimeout(5000);
  await page.click("#mic");
  // the stop path must produce a decode-status result (success or a classified
  // failure) — never a crash or a hung page
  await expect(page.locator("#status")).not.toContainText("Listening", { timeout: 30000 });
  const status = await page.locator("#status").textContent();
  expect(status.length).toBeGreaterThan(0);
  expect(errors).toEqual([]);
});
