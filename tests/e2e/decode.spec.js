const { test, expect } = require("@playwright/test");
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

function buildAudio() {
  const out = path.join(__dirname, "..", "..", "tmp-e2e");
  fs.mkdirSync(out, { recursive: true });
  execSync(
    `${path.join(__dirname, "..", "..", "zig-out", "bin", "cairn")} build example/index.md --output ${out}/audio-page.html --audio ${out}/audio-relay.wav`,
    { cwd: path.join(__dirname, "..", ".."), stdio: "pipe" }
  );
  return out;
}

test("decode.html: mic toggle starts and stops without crash", async ({ page }) => {
  buildAudio();
  // no real mic hardware: stub getUserMedia, the worklet constructor (the
  // page only needs its port), and the media stream source node
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "mediaDevices", {
      value: { getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] }) },
      configurable: true,
    });
    window.AudioWorkletNode = function () {
      this.port = { onmessage: null };
      this.connect = function () {};
      this.disconnect = function () {};
    };
    const AC = window.AudioContext || window.webkitAudioContext;
    if (AC && AC.prototype) {
      AC.prototype.createMediaStreamSource = function () { return { connect() {} }; };
    }
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/decode.html");
  await page.click("#mic");
  await expect(page.locator("#status")).toContainText("Listening");
  await expect(page.locator("#mic")).toHaveText("Stop microphone");
  await page.click("#mic");
  await expect(page.locator("#status")).not.toContainText("Listening");
  await expect(page.locator("#mic")).toHaveText("Start microphone decode");
  expect(errors).toEqual([]);
});
