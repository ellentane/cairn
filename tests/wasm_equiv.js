"use strict";
// JS/WASM bytecode-equivalence harness: boots the same program through both
// VMs (src/vm.js and zig-out/bin/vm_wasm.wasm) against identical mock DOMs and
// asserts identical DOM snapshots after every interaction — textContent, value,
// classList, and registered events — so a failing wasm handler (which only
// console.errors with a code) is caught as a snapshot divergence.
//
//   node tests/wasm_equiv.js            run the 7 equivalence scenarios
//   node tests/wasm_equiv.js --check-ops  decode every scenario program and
//                                       fail unless all 27 opcodes are covered
const fs = require("fs");
const path = require("path");
const bc = require("./bytecode.js");

const OP = bc.OPCODES;

// long-value coverage: extracts and STORE_VAR values that exceed the old
// 255-byte value cap — the heap-backed wasm VM must round-trip them in full
const LONG_SENT = "the quick brown fox jumps over the lazy dog";
const LONG_TEXT = (LONG_SENT + " ").repeat(7); // 308 chars, ~300
const LONG_TEXT2 = "0123456789".repeat(200); // 2000 chars
const STORE_TEXT = "stored-value-literal-0123456789-".repeat(10); // 310 chars

function MockClassList(node) { this.node = node; this.set = new Set(); }
MockClassList.prototype.add = function (c) { this.set.add(c); };
MockClassList.prototype.remove = function (c) { this.set.delete(c); };
MockClassList.prototype.toggle = function (c) { this.set.has(c) ? this.set.delete(c) : this.set.add(c); };
MockClassList.prototype.has = function (c) { return this.set.has(c); };

function MockNode(id) {
  this.id = id;
  this._text = "";
  this.value = "";
  this.classList = new MockClassList(this);
  this.handlers = {};
  Object.defineProperty(this, "textContent", {
    get: () => this._text,
    set: (v) => { this._text = v; for (const fn of this.handlers["input"] || []) fn(); },
  });
}
MockNode.prototype.addEventListener = function (ev, fn) {
  (this.handlers[ev] = this.handlers[ev] || []).push(fn);
};
MockNode.prototype.fire = function (ev) { for (const fn of this.handlers[ev] || []) fn(); };

function MockDoc() { this.nodes = {}; }
MockDoc.prototype.add = function (n) { this.nodes[n.id] = n; };
MockDoc.prototype.querySelectorAll = function (sel) {
  const out = [];
  if (sel.startsWith("#")) {
    const k = sel.slice(1);
    if (this.nodes[k]) out.push(this.nodes[k]);
  } else if (sel === "*") {
    out.push(...Object.values(this.nodes));
  }
  return out;
};

function snapshot(doc) {
  const out = {};
  for (const id of Object.keys(doc.nodes).sort()) {
    const n = doc.nodes[id];
    out[id] = {
      text: n.textContent,
      value: n.value,
      classes: [...n.classList.set].sort(),
      events: Object.keys(n.handlers).sort().map((k) => k + ":" + n.handlers[k].length),
    };
  }
  return JSON.stringify(out);
}

let passed = 0, failed = 0;
const scenarios = [];
function scenario(name, progFn, body) { scenarios.push([name, progFn, body]); }

function makePair(ids, initial) {
  const dj = new MockDoc(), dw = new MockDoc();
  for (const id of ids) { dj.add(new MockNode(id)); dw.add(new MockNode(id)); }
  if (initial) initial(dj, dw);
  return [dj, dw];
}

function bootBoth(failures, label, prog, dj, dw) {
  try { bootJs(prog, dj); } catch (e) { failures.push(label + ": JS boot threw " + e.message); }
  try { bootWasm(wasmBytes, prog, dw); } catch (e) { failures.push(label + ": WASM boot threw " + e.message); }
}

function fireBoth(failures, label, dj, dw, id, ev) {
  try { dj.nodes[id].fire(ev); }
  catch (e) { failures.push(label + ": JS handler threw " + e.message); return; }
  dw.nodes[id].fire(ev);
}

function step(failures, label, dj, dw) {
  const sj = snapshot(dj), sw = snapshot(dw);
  if (sj !== sw) failures.push(label + ":\n  JS   " + sj + "\n  WASM " + sw);
}

function expectEq(failures, label, actual, expected) {
  if (actual !== expected) failures.push(label + ": got " + JSON.stringify(actual) + " expected " + JSON.stringify(expected));
}

function runScenario(name, progFn, body) {
  const failures = [];
  let progs = null;
  try { progs = programList(progFn()); } catch (e) { failures.push("program build threw " + e.message); }
  if (progs) {
    try { body(failures, progs); } catch (e) { failures.push("exception: " + e.message); }
  }
  if (failures.length) {
    failed++;
    console.error("FAIL " + name);
    for (const f of failures) console.error("  " + f);
  } else {
    passed++;
    console.log("PASS " + name);
  }
}

// 1. v0.1 fixture V1: click #btn -> "Status: 1" on #out
scenario("1: V1 fixture (set_text handler)",
  () => bc.parseBin(fs.readFileSync(path.join(__dirname, "fixtures", "v0.1", "V1.bin"), "utf8")),
  (f, progs) => {
    const [prog] = progs;
    const [dj, dw] = makePair(["btn", "out"]);
    bootBoth(f, "V1", prog, dj, dw);
    step(f, "V1 boot", dj, dw);
    fireBoth(f, "V1 click #btn", dj, dw, "btn", "click");
    step(f, "V1 click #btn", dj, dw);
    expectEq(f, "V1 #out", dj.nodes.out.textContent, "Status: 1");
  });

// 2. v0.1 fixture V2: two bindings; click #a must not leak into #b's handler
scenario("2: V2 fixture (two bindings, cross-wire guard)",
  () => bc.parseBin(fs.readFileSync(path.join(__dirname, "fixtures", "v0.1", "V2.bin"), "utf8")),
  (f, progs) => {
    const [prog] = progs;
    const [dj, dw] = makePair(["a", "b"]);
    bootBoth(f, "V2", prog, dj, dw);
    step(f, "V2 boot", dj, dw);
    fireBoth(f, "V2 click #a", dj, dw, "a", "click");
    step(f, "V2 click #a", dj, dw);
    expectEq(f, "V2 #a", dj.nodes.a.textContent, "1");
    expectEq(f, "V2 #b untouched", dj.nodes.b.classList.has("x"), false);
    fireBoth(f, "V2 input #b", dj, dw, "b", "input");
    step(f, "V2 input #b", dj, dw);
    expectEq(f, "V2 #b class", dj.nodes.b.classList.has("x"), true);
  });

// 3. v0.1 fixture V3: extract_text + if, matching and non-matching
scenario("3: V3 fixture (extract_text + if)",
  () => bc.parseBin(fs.readFileSync(path.join(__dirname, "fixtures", "v0.1", "V3.bin"), "utf8")),
  (f, progs) => {
    const [prog] = progs;
    const [dj, dw] = makePair(["go", "src", "dst"],
      (a, b) => { a.nodes.src.textContent = "yes"; b.nodes.src.textContent = "yes"; });
    bootBoth(f, "V3", prog, dj, dw);
    step(f, "V3 boot", dj, dw);
    fireBoth(f, "V3 click #go (src=yes)", dj, dw, "go", "click");
    step(f, "V3 click #go (src=yes)", dj, dw);
    expectEq(f, "V3 #dst matched", dj.nodes.dst.textContent, "hit");
    dj.nodes.src.textContent = "no";
    dw.nodes.src.textContent = "no";
    dj.nodes.dst.textContent = "";
    dw.nodes.dst.textContent = "";
    fireBoth(f, "V3 click #go (src=no)", dj, dw, "go", "click");
    step(f, "V3 click #go (src=no)", dj, dw);
    expectEq(f, "V3 #dst unmatched", dj.nodes.dst.textContent, "");
  });

// 4. vector A: let + inc; a CMP_EQ + JMP_IF_TRUE branch picks "first" on
//    click 1 (c=1) and "second" on click 2 (c=2), firing the jump both ways
scenario("4: let + inc counter (vector A, click twice)", () => new bc.Asm()
  .byte(OP.PUSH_STR).str("0").byte(OP.STORE_VAR).str("c")
  .byte(OP.PUSH_SELECTOR).str("#b").byte(OP.GET_NODES).onEvent("click", "inc")
  .byte(OP.HALT)
  .label("inc")
  .byte(OP.INC).str("c")
  .byte(OP.PUSH_VAR).str("c").byte(OP.PUSH_STR).str("2").byte(OP.CMP_EQ)
  .byte(OP.JMP_IF_TRUE).ref16("second")
  .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("first")
  .jump("done")
  .label("second")
  .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("second")
  .label("done").byte(OP.HALT).finish(),
  (f, progs) => {
    const [prog] = progs;
    const [dj, dw] = makePair(["b", "out"]);
    bootBoth(f, "S4", prog, dj, dw);
    step(f, "S4 boot", dj, dw);
    fireBoth(f, "S4 click #b (1st)", dj, dw, "b", "click");
    step(f, "S4 click 1", dj, dw);
    expectEq(f, "S4 #out after 1 click", dj.nodes.out.textContent, "first");
    fireBoth(f, "S4 click #b (2nd)", dj, dw, "b", "click");
    step(f, "S4 click 2", dj, dw);
    expectEq(f, "S4 #out after 2 clicks", dj.nodes.out.textContent, "second");
  });

// 5. vector B: if/else both branches; branch value baked into the program
//    (the wasm VM exposes no state handle). The if branch toggles a class,
//    the else branch adds and removes one (REMOVE_CLASS is observable because
//    #out starts with "r").
scenario("5: if/else + class ops both branches (vector B)",
  () => {
    const make = (c) => new bc.Asm()
      .byte(OP.PUSH_STR).str(c).byte(OP.STORE_VAR).str("c")
      .byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES).onEvent("click", "h")
      .byte(OP.HALT)
      .label("h")
      .byte(OP.PUSH_VAR).str("c").byte(OP.PUSH_STR).str("1").byte(OP.CMP_EQ)
      .jif("els")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("one")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.TOGGLE_CLASS).str("t")
      .jump("done")
      .label("els")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("other")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.ADD_CLASS).str("a")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.REMOVE_CLASS).str("r")
      .label("done").byte(OP.HALT).finish();
    return [make("1"), make("2")];
  },
  (f, progs) => {
    const [p1, p2] = progs;
    const [dj1, dw1] = makePair(["btn", "out"],
      (a, b) => { a.nodes.out.classList.add("r"); b.nodes.out.classList.add("r"); });
    bootBoth(f, "S5 c=1", p1, dj1, dw1);
    step(f, "S5 boot c=1", dj1, dw1);
    fireBoth(f, "S5 click #btn (c=1)", dj1, dw1, "btn", "click");
    step(f, "S5 click c=1", dj1, dw1);
    expectEq(f, "S5 #out c=1", dj1.nodes.out.textContent, "one");
    expectEq(f, "S5 #out toggle t", dj1.nodes.out.classList.has("t"), true);
    expectEq(f, "S5 #out keeps r", dj1.nodes.out.classList.has("r"), true);
    const [dj2, dw2] = makePair(["btn", "out"],
      (a, b) => { a.nodes.out.classList.add("r"); b.nodes.out.classList.add("r"); });
    bootBoth(f, "S5 c=2", p2, dj2, dw2);
    step(f, "S5 boot c=2", dj2, dw2);
    fireBoth(f, "S5 click #btn (c=2)", dj2, dw2, "btn", "click");
    step(f, "S5 click c=2", dj2, dw2);
    expectEq(f, "S5 #out c=2", dj2.nodes.out.textContent, "other");
    expectEq(f, "S5 #out add a", dj2.nodes.out.classList.has("a"), true);
    expectEq(f, "S5 #out remove r", dj2.nodes.out.classList.has("r"), false);
  });

// 6. while + all four numeric comparators + extract_value + set_text(expr).
//    Fire 1 (inp=7) and fire 2 (inp=2) flip every comparator outcome so each
//    fires both ways; the loop runs on fire 1 and is skipped on fire 2.
scenario("6: while + comparators + extract_value + set_text(expr)", () => new bc.Asm()
  .byte(OP.PUSH_STR).str("0").byte(OP.STORE_VAR).str("n")
  .byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES).onEvent("click", "w")
  .byte(OP.HALT)
  .label("w")
  .byte(OP.PUSH_VAR).str("n").byte(OP.PUSH_STR).str("3").byte(OP.CMP_LT)
  .jif("loopdone")
  .byte(OP.INC).str("n")
  .jump("w")
  .label("loopdone")
  .byte(OP.PUSH_VAR).str("n")
  .byte(OP.PUSH_SELECTOR).str("#mid").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
  .byte(OP.PUSH_SELECTOR).str("#inp").byte(OP.GET_NODES).byte(OP.EXTRACT_VALUE).str("v")
  .byte(OP.PUSH_VAR).str("v").byte(OP.PUSH_STR).str("5").byte(OP.CMP_GE)
  .jif("gefail")
  .byte(OP.PUSH_SELECTOR).str("#ge").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("ge-ok")
  .jump("geend")
  .label("gefail")
  .byte(OP.PUSH_SELECTOR).str("#ge").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("ge-fail")
  .label("geend")
  .byte(OP.PUSH_VAR).str("v").byte(OP.PUSH_STR).str("5").byte(OP.CMP_LE)
  .jif("lefail")
  .byte(OP.PUSH_SELECTOR).str("#le").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("le-ok")
  .jump("leend")
  .label("lefail")
  .byte(OP.PUSH_SELECTOR).str("#le").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("le-fail")
  .label("leend")
  .byte(OP.PUSH_VAR).str("v").byte(OP.PUSH_STR).str("5").byte(OP.CMP_GT)
  .jif("gtfail")
  .byte(OP.PUSH_SELECTOR).str("#gt").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("gt-ok")
  .jump("gtend")
  .label("gtfail")
  .byte(OP.PUSH_SELECTOR).str("#gt").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("gt-fail")
  .label("gtend")
  .byte(OP.PUSH_VAR).str("v").byte(OP.PUSH_STR).str("7").byte(OP.CMP_NE)
  .jif("neq")
  .byte(OP.PUSH_SELECTOR).str("#ne").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("ne-fail")
  .jump("neend")
  .label("neq")
  .byte(OP.PUSH_SELECTOR).str("#ne").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("ne-ok")
  .label("neend")
  .byte(OP.PUSH_VAR).str("n").byte(OP.PUSH_STR).str("1").byte(OP.SUB_NUM)
  .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
  .byte(OP.PUSH_VAR).str("v").byte(OP.PUSH_STR).str("1").byte(OP.ADD_NUM)
  .byte(OP.PUSH_SELECTOR).str("#res").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
  .byte(OP.PUSH_SELECTOR).str("#longsrc").byte(OP.GET_NODES).byte(OP.EXTRACT_TEXT).str("long")
  .byte(OP.PUSH_VAR).str("long")
  .byte(OP.PUSH_SELECTOR).str("#longout").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
  .byte(OP.PUSH_SELECTOR).str("#longsrc2").byte(OP.GET_NODES).byte(OP.EXTRACT_TEXT).str("long2")
  .byte(OP.PUSH_VAR).str("long2")
  .byte(OP.PUSH_SELECTOR).str("#longout2").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
  .byte(OP.PUSH_STR).str(STORE_TEXT)
  .byte(OP.STORE_VAR).str("big")
  .byte(OP.PUSH_VAR).str("big")
  .byte(OP.PUSH_SELECTOR).str("#storeout").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
  .byte(OP.HALT).finish(),
  (f, progs) => {
    const [prog] = progs;
    const [dj, dw] = makePair(["btn", "mid", "out", "res", "inp", "ge", "le", "gt", "ne", "longsrc", "longout", "longsrc2", "longout2", "storeout"],
      (a, b) => {
        a.nodes.inp.value = "7"; b.nodes.inp.value = "7";
        a.nodes.longsrc.textContent = LONG_TEXT; b.nodes.longsrc.textContent = LONG_TEXT;
        a.nodes.longsrc2.textContent = LONG_TEXT2; b.nodes.longsrc2.textContent = LONG_TEXT2;
      });
    bootBoth(f, "S6", prog, dj, dw);
    step(f, "S6 boot", dj, dw);
    fireBoth(f, "S6 click #btn (inp=7)", dj, dw, "btn", "click");
    step(f, "S6 click inp=7", dj, dw);
    expectEq(f, "S6 #mid (loop result)", dj.nodes.mid.textContent, "3");
    expectEq(f, "S6 #out (n-1)", dj.nodes.out.textContent, "2");
    expectEq(f, "S6 #res (v+1)", dj.nodes.res.textContent, "8");
    expectEq(f, "S6 #ge (v>=5)", dj.nodes.ge.textContent, "ge-ok");
    expectEq(f, "S6 #le (v<=5)", dj.nodes.le.textContent, "le-fail");
    expectEq(f, "S6 #gt (v>5)", dj.nodes.gt.textContent, "gt-ok");
    expectEq(f, "S6 #ne (v!=7)", dj.nodes.ne.textContent, "ne-ok");
    expectEq(f, "S6 #longout (full " + LONG_TEXT.length + " chars)", dj.nodes.longout.textContent, LONG_TEXT);
    expectEq(f, "S6 #longout wasm", dw.nodes.longout.textContent, LONG_TEXT);
    expectEq(f, "S6 #longout2 (full " + LONG_TEXT2.length + " chars)", dj.nodes.longout2.textContent, LONG_TEXT2);
    expectEq(f, "S6 #longout2 wasm", dw.nodes.longout2.textContent, LONG_TEXT2);
    expectEq(f, "S6 #storeout (STORE_VAR read-back, full " + STORE_TEXT.length + " chars)", dj.nodes.storeout.textContent, STORE_TEXT);
    expectEq(f, "S6 #storeout wasm", dw.nodes.storeout.textContent, STORE_TEXT);
    dj.nodes.inp.value = "2";
    dw.nodes.inp.value = "2";
    fireBoth(f, "S6 click #btn (inp=2)", dj, dw, "btn", "click");
    step(f, "S6 click inp=2", dj, dw);
    expectEq(f, "S6 #mid persists", dj.nodes.mid.textContent, "3");
    expectEq(f, "S6 #out (n-1)", dj.nodes.out.textContent, "2");
    expectEq(f, "S6 #res (v+1)", dj.nodes.res.textContent, "3");
    expectEq(f, "S6 #ge (v>=5)", dj.nodes.ge.textContent, "ge-fail");
    expectEq(f, "S6 #le (v<=5)", dj.nodes.le.textContent, "le-ok");
    expectEq(f, "S6 #gt (v>5)", dj.nodes.gt.textContent, "gt-fail");
    expectEq(f, "S6 #ne (v!=7)", dj.nodes.ne.textContent, "ne-fail");
    expectEq(f, "S6 #longout (2nd) wasm", dw.nodes.longout.textContent, LONG_TEXT);
    expectEq(f, "S6 #longout2 (2nd) wasm", dw.nodes.longout2.textContent, LONG_TEXT2);
    expectEq(f, "S6 #storeout (2nd) wasm", dw.nodes.storeout.textContent, STORE_TEXT);
  });

// 7. formatter alignment (§5.2): 0.1 + 0.2 must render the same decimal in
//    both engines
scenario("7: formatter alignment (0.1 + 0.2)", () => new bc.Asm()
  .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).onEvent("load", "h").byte(OP.HALT)
  .label("h")
  .byte(OP.PUSH_STR).str("0.1").byte(OP.PUSH_STR).str("0.2").byte(OP.ADD_NUM)
  .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
  .byte(OP.HALT).finish(),
  (f, progs) => {
    const [prog] = progs;
    const [dj, dw] = makePair(["out"]);
    bootBoth(f, "S7", prog, dj, dw);
    step(f, "S7 boot", dj, dw);
    fireBoth(f, "S7 load #out", dj, dw, "out", "load");
    step(f, "S7 load #out", dj, dw);
    expectEq(f, "S7 #out (JS)", dj.nodes.out.textContent, "0.30000000000000004");
    expectEq(f, "S7 #out (WASM)", dw.nodes.out.textContent, "0.30000000000000004");
  });

// progFn may return one program (Uint8Array or plain byte array) or an array
// of program variants; both are normalized to a list of programs.
function programList(built) {
  if (built instanceof Uint8Array) return [built];
  if (Array.isArray(built) && built.length > 0 && typeof built[0] === "number") return [built];
  return built;
}

function checkOps() {
  const seen = new Set();
  for (const [name, progFn] of scenarios) {
    let progs;
    try { progs = programList(progFn()); }
    catch (e) { console.error("FAIL --check-ops: " + name + " program build threw " + e.message); process.exitCode = 1; continue; }
    for (const prog of progs) {
      try { for (const ins of bc.decode(Uint8Array.from(prog))) seen.add(ins.op); }
      catch (e) { console.error("FAIL --check-ops: " + name + " does not decode: " + e.message); process.exitCode = 1; }
    }
  }
  const missing = [];
  for (let op = 1; op <= 27; op++) if (!seen.has(op)) missing.push(op);
  console.log("opcode coverage: " + seen.size + "/27 across " + scenarios.length + " scenarios"
    + (missing.length ? " — MISSING " + missing.join(",") : ""));
  if (missing.length) process.exitCode = 1;
}

function main() {
  if (process.argv.indexOf("--check-ops") >= 0) { checkOps(); return; }
  const jsSrc = fs.readFileSync(path.join(__dirname, "..", "src", "vm.js"), "utf8");
  const glueSrc = fs.readFileSync(path.join(__dirname, "..", "src", "wasm_glue.js"), "utf8");
  bootJs = new Function(jsSrc + "\n;return cairnBoot;")();
  bootWasm = new Function(glueSrc + "\n;return cairnBootWasm;")();
  const wasmPath = path.join(__dirname, "..", "zig-out", "bin", "vm_wasm.wasm");
  if (!fs.existsSync(wasmPath)) {
    console.error("wasm_equiv: run `zig build` first — missing zig-out/bin/vm_wasm.wasm");
    process.exit(1);
  }
  wasmBytes = fs.readFileSync(wasmPath);
  for (const [name, progFn, body] of scenarios) runScenario(name, progFn, body);
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exitCode = failed ? 1 : 0;
}

let bootJs, bootWasm, wasmBytes;
main();
