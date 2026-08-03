const { test, expect } = require("@playwright/test");
const { execSync, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

function scrubDataUris(html) {
  let out = "";
  let rest = html;
  for (;;) {
    const idx = rest.indexOf("data:");
    if (idx === -1) return out + rest;
    out += rest.slice(0, idx);
    let end = idx + 5;
    let comma = false;
    while (end < rest.length) {
      const c = rest[end];
      if (c === ",") { comma = true; end++; continue; }
      if (comma) {
        if (c === '"' || c === ">" || c === "\n" || c === "\r") break;
      } else if (c === " " || c === "\t" || c === '"' || c === "'" || c === ">" || c === "\n" || c === "\r") break;
      end++;
    }
    rest = rest.slice(end);
  }
}

test("built page contains no http(s) references (hermeticity audit)", () => {
  execSync(`${path.join(__dirname, "..", "..", "zig-out", "bin", "cairn")} build example/index.md --output /tmp/cairn-e2e-herm.html`, { cwd: path.join(__dirname, "..", "..") });
  const html = fs.readFileSync("/tmp/cairn-e2e-herm.html", "utf8");
  const scrubbed = scrubDataUris(html);
  expect(scrubbed).not.toMatch(/https?:\/\//);
});
