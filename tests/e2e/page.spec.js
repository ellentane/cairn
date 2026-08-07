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

test("last box: the clock runs on your time", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  // the built page renders asynchronously (VM boot builds the DOM); wait for
  // the element before asserting — parallel workers can delay the boot
  await page.locator("#clock").waitFor({ state: "attached", timeout: 15000 });
  await expect(page.locator("#clock")).toHaveText("5:14");
  await page.click("#mug-btn");
  await expect(page.locator("#clock")).toHaveText("5:15");
  await expect(page.locator("#total")).toHaveText("400");
  await expect(page.locator("#left")).toHaveText("2600");
  await expect(page.locator("#story")).toHaveText("the chip on the rim is from the morning you moved in.");
});

test("last box: the box won't close", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.click("#coat-btn");
  await page.click("#cassette-btn");
  await expect(page.locator("#total")).toHaveText("3000");
  await page.click("#mug-btn");
  await expect(page.locator("#fb")).toHaveText("the box won't close. something has to come out.");
  await expect(page.locator("#total")).toHaveText("3000");
});

test("last box: the drawer reveals the note", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await expect(page.locator("#note-row")).toBeHidden();
  await page.click("#drawer-btn");
  await expect(page.locator("#note-row")).toBeVisible();
  await expect(page.locator("#story")).toHaveText("the drawer is open. the note is inside.");
});

test("last box: the room darkens as time passes", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  for (let i = 0; i < 11; i++) await page.click("#mug-btn");
  await expect(page.locator("#clock")).toHaveText("5:25");
  await expect(page.locator("#room")).toHaveClass(/dusk/);
  for (let i = 0; i < 18; i++) await page.click("#mug-btn");
  await expect(page.locator("#clock")).toHaveText("5:43");
  await expect(page.locator("#room")).toHaveClass(/gone/);
});

test("last box: you make it with time to spare", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.click("#mug-btn");
  await page.fill("#name", "ada");
  await page.click("#seal");
  await expect(page.locator("#e-time")).toHaveText("5:15.");
  await expect(page.locator("#e-l1")).toHaveText("you made it with time to spare.");
  await expect(page.locator("#e-name")).toHaveText("ada");
  await expect(page.locator("#e-mug")).toHaveText("the mug is packed. you will drink from it somewhere else.");
  await expect(page.locator("#e-note-left")).toHaveText("the note stays in the drawer, unread.");
  await expect(page.locator("#e-final")).toHaveText("the room is empty. it was a good room. someone else will say that, too.");
});

test("last box: you miss the train", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  for (let i = 0; i < 29; i++) await page.click("#mug-btn");
  await page.fill("#name", "ada");
  await page.click("#seal");
  await expect(page.locator("#e-time")).toHaveText("5:43.");
  await expect(page.locator("#e-l1")).toHaveText("the train is gone. you stay the night.");
  await expect(page.locator("#e-stay")).toHaveText("you unpack. the box can wait until tomorrow. the room is not empty tonight.");
  await expect(page.locator("#e-l2")).toHaveText("you leave the box where it is.");
  await expect(page.locator("#e-name")).toHaveText("");
});

test("last box: the empty box has its own ending", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.fill("#name", "ada");
  await page.click("#seal");
  await expect(page.locator("#e-l2")).toHaveText("you seal the empty box. there was nothing to take.");
  await expect(page.locator("#e-final")).toHaveText("the room is empty, and so is the box.");
});

test("last box: rows catch the light on hover", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.hover("#row-mug");
  await expect(page.locator("#row-mug")).toHaveClass(/lit/);
});

test("last box: no network requests", async ({ page }) => {
  build("example/index.md");
  const requests = [];
  page.on("request", (r) => requests.push(r.url()));
  await page.goto("/");
  await page.click("#mug-btn");
  expect(requests.length).toBe(1);
  expect(requests[0].startsWith("http://127.0.0.1:8931")).toBe(true);
});

test("decimal debug-encoding page still boots", async ({ page }) => {
  build("example/index.md", "--debug-encoding");
  await page.goto("/");
  await page.click("#mug-btn");
  await expect(page.locator("#total")).toHaveText("400");
});

test("base64 transport page boots", async ({ page }) => {
  build("example/index.md");
  await page.goto("/");
  await page.click("#mug-btn");
  await expect(page.locator("#total")).toHaveText("400");
});
