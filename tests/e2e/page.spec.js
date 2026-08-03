const { test, expect } = require("@playwright/test");
const { execSync, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

function build(target, flags = "") {
  const out = path.join(__dirname, "..", "..", "tmp-e2e");
  fs.mkdirSync(out, { recursive: true });
  execSync(`${path.join(__dirname, "..", "..", "zig-out", "bin", "cairn")} build ${target} --output ${out}/index.html ${flags}`, { cwd: path.join(__dirname, "..", ".."), stdio: "pipe" });
  return out;
}

test("built example: click sets text", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.click("#btn");
  await expect(page.locator("#out")).toHaveText("Status: 1");
});

test("built example: counter reaches three clicks", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.click("#inc");
  await expect(page.locator("#out")).toHaveText("1 clicks");
  await page.click("#inc");
  await page.click("#inc");
  await expect(page.locator("#out")).toHaveText("three clicks!");
});

test("built example: input echo via extract_value", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.fill("#name", "cairn");
  await page.locator("#name").dispatchEvent("input");
  await expect(page.locator("#out")).toHaveText("hello cairn");
});

test("built example: hover adds class", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.hover("#box");
  await expect(page.locator("#box")).toHaveClass(/lit/);
});

test("built example: no network requests", async ({ page }) => {
  build("example/index.md");
  const requests = [];
  page.on("request", (r) => requests.push(r.url()));
  await page.goto("/");
  await page.click("#inc");
  expect(requests.every((u) => u.startsWith("http://127.0.0.1:8931"))).toBe(true);
});

test("decimal debug-encoding page still boots", async ({ page }) => {
  build("example/index.md", "--debug-encoding");
  await page.goto("/");
  await page.click("#btn");
  await expect(page.locator("#out")).toHaveText("Status: 1");
});

test("base64 transport page boots", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.click("#chk");
  await expect(page.locator("#status")).toHaveText("pending");
  await page.evaluate(() => { document.getElementById("status").textContent = "done"; });
  await page.click("#chk");
  await expect(page.locator("#status")).toHaveText("already done");
});
