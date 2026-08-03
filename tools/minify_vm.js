"use strict";
// Safe lexical minifier for src/vm.js: strips // comments, leading indentation,
// and blank lines. String-aware: never touches content inside "..." literals.
//
// Lexical contract (must hold for src/vm.js): double-quoted strings only (no
// single quotes, no template literals); strings never span lines; no " or //
// inside regex literals. Violations silently corrupt output — the dual-file
// test suite (vm.js + vm.min.js) catches them when regeneration happens.
const fs = require("fs");
const path = require("path");

const inPath = process.argv[2] || path.join(__dirname, "..", "src", "vm.js");
const outPath = process.argv[3] || path.join(__dirname, "..", "src", "vm.min.js");

const src = fs.readFileSync(inPath, "utf8");
const lines = src.split("\n");
const out = [];
for (let line of lines) {
  let inStr = false;
  let cleaned = "";
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inStr) {
      cleaned += ch;
      if (ch === "\\") { cleaned += line[i + 1] || ""; i++; }
      else if (ch === '"') inStr = false;
      continue;
    }
    if (ch === '"') { inStr = true; cleaned += ch; continue; }
    if (ch === "/" && line[i + 1] === "/") break; // comment
    cleaned += ch;
  }
  const trimmed = cleaned.trimEnd();
  if (trimmed.trimStart().length === 0) continue; // blank
  out.push(trimmed.replace(/^ +/, ""));
}
fs.writeFileSync(outPath, out.join("\n") + "\n");
console.log(`minified ${inPath} -> ${outPath} (${out.join("\n").length} bytes)`);
