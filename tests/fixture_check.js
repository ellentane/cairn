"use strict";
const fs = require("fs");
const path = require("path");
const bc = require("./bytecode.js");

// Per-version opcode allowlists (§5.1 `since` column as data).
const ALLOWED = { "v0.1": new Set([1,2,3,4,5,6,7,8,9,10,11,12,13,14]) };

const dir = path.join(__dirname, "fixtures", "v0.1");
let failures = 0;
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".bin")).sort()) {
  const name = f.replace(/\.bin$/, "");
  const bin = bc.parseBin(fs.readFileSync(path.join(dir, f), "utf8"));
  const expected = JSON.parse(fs.readFileSync(path.join(dir, name + ".expected.json"), "utf8"));
  let ins;
  try {
    ins = bc.decode(bin);
  } catch (e) {
    console.error(`FAIL ${name}: decode: ${e.message}`);
    failures++;
    continue;
  }
  // 1. instruction listing must match expected
  const got = ins.map((x) => ({ pos: x.pos, name: x.name, ...(x.s !== undefined ? { s: x.s } : {}), ...(x.addr !== undefined ? { addr: x.addr } : {}) }));
  if (JSON.stringify(got) !== JSON.stringify(expected.instructions)) {
    console.error(`FAIL ${name}: listing mismatch`);
    console.error("  got:      " + JSON.stringify(got));
    console.error("  expected: " + JSON.stringify(expected.instructions));
    failures++;
    continue;
  }
  // 1b. dsl round-trip: expected.dsl must equal the cairn fence content of the .md source
  let ok = true;
  {
    const mdPath = path.join(dir, name + ".md");
    if (fs.existsSync(mdPath)) {
      const mdText = fs.readFileSync(mdPath, "utf8");
      const m = /```cairn\n([\s\S]*?)\n```/.exec(mdText);
      if (!m || m[1] !== expected.dsl) {
        console.error(`FAIL ${name}: dsl does not match the .md cairn block`);
        ok = false;
      }
    }
  }
  // 2. structural checks
  const boundaries = new Set(ins.map((x) => x.pos));
  const len = bin.length;
  const halt = ins.find((x) => x.name === "HALT");
  if (!halt) { console.error(`FAIL ${name}: no HALT`); ok = false; }
  for (const it of ins) {
    if (it.addr !== undefined) {
      if (it.addr > len) { console.error(`FAIL ${name}: ${it.name}@${it.pos} addr ${it.addr} past end`); ok = false; continue; }
      if (it.addr === len) continue; // end-of-stream termination is legal
      if (!boundaries.has(it.addr)) { console.error(`FAIL ${name}: ${it.name}@${it.pos} addr ${it.addr} not on boundary`); ok = false; }
      if ((it.name === "ON_EVENT" || it.name === "JUMP" || it.name === "JMP_IF_FALSE") && it.addr <= halt.pos) { console.error(`FAIL ${name}: ${it.name} addr in prologue`); ok = false; }
    }
    if (!ALLOWED["v0.1"].has(it.op)) { console.error(`FAIL ${name}: opcode 0x${it.op.toString(16)} not allowed in v0.1`); ok = false; }
  }
  if (ok) console.log(`PASS ${name}: ${len} bytes, ${ins.length} instructions`);
  else failures++;
}
console.log(failures ? `\n${failures} FAILURE(S)` : "\nALL FIXTURES VALID");
process.exitCode = failures ? 1 : 0;
