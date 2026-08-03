"use strict";
const fs = require("fs");
const path = require("path");
const bc = require("./bytecode.js");

// Per-version opcode allowlists (§5.1 `since` column as data).
const VERSIONS = {
  "v0.1": new Set([1,2,3,4,5,6,7,8,9,10,11,12,13,14]),
  "v0.2": new Set([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27]),
};
const version = process.argv[3] || (process.argv[2] && process.argv[2] !== "--update" ? process.argv[2] : null) || "v0.1";
const allowed = VERSIONS[version];
if (!allowed) { console.error("unknown version " + version + " (usage: fixture_check.js [--update] [v0.1|v0.2])"); process.exit(2); }

const dir = path.join(__dirname, "fixtures", version);
if (!fs.existsSync(dir)) {
  console.error(`fixture dir not found: ${dir} (run --update to generate)`);
  process.exit(2);
}

function extractDslFromMd(mdPath) {
  const text = fs.readFileSync(mdPath, "utf8");
  const m = /```cairn\n([\s\S]*?)\n```/.exec(text);
  if (!m) throw new Error("no cairn block in " + mdPath);
  return m[1];
}
function compactJson(obj) {
  return "{" + Object.keys(obj).map((k) => JSON.stringify(k) + ": " + JSON.stringify(obj[k])).join(", ") + "}";
}
let failures = 0;
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".bin")).sort()) {
  const name = f.replace(/\.bin$/, "");
  const bin = bc.parseBin(fs.readFileSync(path.join(dir, f), "utf8"));
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
  const len = bin.length;
  if (process.argv[2] === "--update") {
    const dsl = extractDslFromMd(path.join(dir, name + ".md"));
    const out = "{\n  \"dsl\": " + JSON.stringify(dsl) + ",\n  \"instructions\": [\n" +
      got.map((x) => "    " + compactJson(x)).join(",\n") + "\n  ],\n  \"len\": " + len + "\n}\n";
    fs.writeFileSync(path.join(dir, name + ".expected.json"), out);
    console.log(`UPDATED ${name}`);
    continue;
  }
  const expected = JSON.parse(fs.readFileSync(path.join(dir, name + ".expected.json"), "utf8"));
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
      const dslFromMd = extractDslFromMd(mdPath);
      if (dslFromMd !== expected.dsl) {
        console.error(`FAIL ${name}: dsl does not match the .md cairn block`);
        ok = false;
      }
    }
  }
  // 2. structural checks
  const boundaries = new Set(ins.map((x) => x.pos));
  const halt = ins.find((x) => x.name === "HALT");
  if (!halt) { console.error(`FAIL ${name}: no HALT`); ok = false; }
  for (const it of ins) {
    if (it.addr !== undefined) {
      if (it.addr > len) { console.error(`FAIL ${name}: ${it.name}@${it.pos} addr ${it.addr} past end`); ok = false; continue; }
      if (it.addr === len) continue; // end-of-stream termination is legal
      if (!boundaries.has(it.addr)) { console.error(`FAIL ${name}: ${it.name}@${it.pos} addr ${it.addr} not on boundary`); ok = false; }
      if ((it.name === "ON_EVENT" || it.name === "JUMP" || it.name === "JMP_IF_FALSE" || it.name === "JMP_IF_TRUE") && it.addr <= halt.pos) { console.error(`FAIL ${name}: ${it.name} addr in prologue`); ok = false; }
    }
    if (!allowed.has(it.op)) { console.error(`FAIL ${name}: opcode 0x${it.op.toString(16)} not allowed in ${version}`); ok = false; }
  }
  if (ok) console.log(`PASS ${name}: ${len} bytes, ${ins.length} instructions`);
  else failures++;
}
if (version === "v0.2") {
  const seen = new Set();
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".bin"))) {
    for (const it of bc.decode(bc.parseBin(fs.readFileSync(path.join(dir, f), "utf8")))) seen.add(it.op);
  }
  const EMITTABLE = [...VERSIONS["v0.2"]].filter((o) => o !== 13 && o !== 25); // CMP_STR/JMP_IF_TRUE have no v0.2 emission path
  const missing = EMITTABLE.filter((o) => !seen.has(o));
  if (missing.length) {
    console.error(`FAIL v0.2 opcode coverage: not exercised: ${missing.map((o) => "0x" + o.toString(16)).join(", ")}`);
    failures++;
  } else {
    console.log("PASS v0.2 opcode coverage: all emittable opcodes exercised");
  }
  const migrationBin = fs.readFileSync(path.join(dir, "migration.bin"), "utf8");
  if (!bc.decode(bc.parseBin(migrationBin)).some((x) => x.op === 19)) {
    console.error("FAIL migration fixture does not use CMP_EQ (v0.1 semantics would still apply)");
    failures++;
  }
}
console.log(failures ? `\n${failures} FAILURE(S)` : "\nALL FIXTURES VALID");
process.exitCode = failures ? 1 : 0;
