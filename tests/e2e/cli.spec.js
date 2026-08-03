const { test, expect } = require("@playwright/test");
const { execSync, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

function cairn(args, captureStderr) {
  const r = spawnSync(path.join(__dirname, "..", "..", "zig-out", "bin", "cairn"), args.split(" "), {
    cwd: path.join(__dirname, "..", ".."), encoding: "utf8",
  });
  if (r.status !== 0) throw new Error("cairn exited " + r.status + ": " + r.stderr);
  return captureStderr ? r.stderr : r.stdout;
}

test("budget failure exits non-zero", () => {
  expect(() => cairn("build example/index.md --budget 1")).toThrow();
});

test("budget success prints report (stderr)", () => {
  const out = cairn("build example/index.md --budget 64 --output /tmp/cairn-e2e-budget.html", true);
  expect(out).toContain("Half-Life Score");
});

test("verify passes on a built page (stderr)", () => {
  cairn("build example/index.md --output /tmp/cairn-e2e-verify.html");
  const out = cairn("verify /tmp/cairn-e2e-verify.html", true);
  expect(out).toContain("OK");
});
