const { test, expect } = require("@playwright/test");
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const CAIRN = path.join(__dirname, "..", "..", "zig-out", "bin", "cairn");
const FIXTURE = path.join(__dirname, "fixtures", "counter.md");
const OUT = path.join(__dirname, "..", "..", "tmp-e2e", "wasm.html");

function buildWasm(flags = "") {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  execSync(`${CAIRN} build ${FIXTURE} --vm wasm --output ${OUT} ${flags}`, {
    cwd: path.join(__dirname, "..", ".."), stdio: "pipe",
  });
}

function buildJsStrict() {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  execSync(`${CAIRN} build ${FIXTURE} --strict-format --output ${OUT}`, {
    cwd: path.join(__dirname, "..", ".."), stdio: "pipe",
  });
}

function trackErrors(page) {
  const errors = [];
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text());
  });
  return errors;
}

function expectNoFallback(errors) {
  expect(errors.filter((e) => e.includes("falling back"))).toEqual([]);
}

test("wasm backend: interactions work", async ({ page }) => {
  buildWasm();
  const errors = trackErrors(page);
  await page.goto("/wasm.html");
  await page.click("#inc");
  await page.click("#inc");
  await expect(page.locator("#out")).toHaveText("2 clicks");
  expectNoFallback(errors);
});

test("wasm backend: counter reaches if-branch", async ({ page }) => {
  buildWasm();
  const errors = trackErrors(page);
  await page.goto("/wasm.html");
  await page.click("#inc");
  await page.click("#inc");
  await page.click("#inc");
  await expect(page.locator("#out")).toHaveText("three clicks!");
  expectNoFallback(errors);
});

test("wasm fallback: stubbed WebAssembly uses JS VM", async ({ page }) => {
  buildWasm();
  await page.addInitScript(() => {
    delete window.WebAssembly;
  });
  await page.goto("/wasm.html");
  await page.click("#inc");
  await expect(page.locator("#out")).toHaveText("1 clicks");
});

test("wasm fallback: WebAssembly.instantiate throws", async ({ page }) => {
  buildWasm();
  await page.addInitScript(() => {
    Object.defineProperty(window, "WebAssembly", {
      configurable: true,
      get() { throw new Error("stubbed WebAssembly"); },
    });
  });
  await page.goto("/wasm.html");
  await page.click("#btn");
  await expect(page.locator("#out")).toHaveText("Status: 1");
});

test("strict-format page boots (0x00 0x01 prefix)", async ({ page }) => {
  buildWasm("--strict-format");
  const errors = trackErrors(page);
  await page.goto("/wasm.html");
  await page.click("#btn");
  await expect(page.locator("#out")).toHaveText("Status: 1");
  expectNoFallback(errors);
});

test("strict-format page boots on JS VM", async ({ page }) => {
  buildJsStrict();
  await page.goto("/wasm.html");
  await page.click("#chk");
  await expect(page.locator("#status")).toHaveText("pending");
});

test("wasm page has zero network requests", async ({ page }) => {
  buildWasm();
  const requests = [];
  page.on("request", (r) => requests.push(r.url()));
  await page.goto("/wasm.html");
  await page.click("#inc");
  expect(requests.length).toBe(1);
  expect(requests[0].startsWith("http://127.0.0.1:8931")).toBe(true);
});
