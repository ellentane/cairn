"use strict";
// JS/WASM bytecode-equivalence harness: boots the same program through both
// VMs (src/vm.js and zig-out/bin/vm_wasm.wasm) against identical mock DOMs and
// asserts identical DOM snapshots after every interaction — textContent, value,
// classList, and registered events — so a failing wasm handler (which only
// console.errors with a code) is caught as a snapshot divergence.
const fs = require("fs");
const path = require("path");
const bc = require("./bytecode.js");

const OP = bc.OPCODES;

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
function scenario(name, body) { scenarios.push([name, body]); }

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

function fireBoth(dj, dw, id, ev) {
  dj.nodes[id].fire(ev);
  dw.nodes[id].fire(ev);
}

function step(failures, label, dj, dw) {
  const sj = snapshot(dj), sw = snapshot(dw);
  if (sj !== sw) failures.push(label + ":\n  JS   " + sj + "\n  WASM " + sw);
}

function expectEq(failures, label, actual, expected) {
  if (actual !== expected) failures.push(label + ": got " + JSON.stringify(actual) + " expected " + JSON.stringify(expected));
}

function runScenario(name, body) {
  const failures = [];
  try { body(failures); } catch (e) { failures.push("exception: " + e.message); }
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
scenario("1: V1 fixture (set_text handler)", (f) => {
  const prog = bc.parseBin(fs.readFileSync(path.join(__dirname, "fixtures", "v0.1", "V1.bin"), "utf8"));
  const [dj, dw] = makePair(["btn", "out"]);
  bootBoth(f, "V1", prog, dj, dw);
  step(f, "V1 boot", dj, dw);
  fireBoth(dj, dw, "btn", "click");
  step(f, "V1 click #btn", dj, dw);
  expectEq(f, "V1 #out", dj.nodes.out.textContent, "Status: 1");
});

// 2. v0.1 fixture V2: two bindings; click #a must not leak into #b's handler
scenario("2: V2 fixture (two bindings, cross-wire guard)", (f) => {
  const prog = bc.parseBin(fs.readFileSync(path.join(__dirname, "fixtures", "v0.1", "V2.bin"), "utf8"));
  const [dj, dw] = makePair(["a", "b"]);
  bootBoth(f, "V2", prog, dj, dw);
  step(f, "V2 boot", dj, dw);
  fireBoth(dj, dw, "a", "click");
  step(f, "V2 click #a", dj, dw);
  expectEq(f, "V2 #a", dj.nodes.a.textContent, "1");
  expectEq(f, "V2 #b untouched", dj.nodes.b.classList.has("x"), false);
  fireBoth(dj, dw, "b", "input");
  step(f, "V2 input #b", dj, dw);
  expectEq(f, "V2 #b class", dj.nodes.b.classList.has("x"), true);
});

// 3. v0.1 fixture V3: extract_text + if, matching and non-matching
scenario("3: V3 fixture (extract_text + if)", (f) => {
  const prog = bc.parseBin(fs.readFileSync(path.join(__dirname, "fixtures", "v0.1", "V3.bin"), "utf8"));
  const [dj, dw] = makePair(["go", "src", "dst"], (a, b) => { a.nodes.src.textContent = "yes"; b.nodes.src.textContent = "yes"; });
  bootBoth(f, "V3", prog, dj, dw);
  step(f, "V3 boot", dj, dw);
  fireBoth(dj, dw, "go", "click");
  step(f, "V3 click #go (src=yes)", dj, dw);
  expectEq(f, "V3 #dst matched", dj.nodes.dst.textContent, "hit");
  dj.nodes.src.textContent = "no";
  dw.nodes.src.textContent = "no";
  dj.nodes.dst.textContent = "";
  dw.nodes.dst.textContent = "";
  fireBoth(dj, dw, "go", "click");
  step(f, "V3 click #go (src=no)", dj, dw);
  expectEq(f, "V3 #dst unmatched", dj.nodes.dst.textContent, "");
});

// 4. vector A: let + inc; state echoed to #out so handler execution is observable
scenario("4: let + inc counter (vector A, click twice)", (f) => {
  const prog = new bc.Asm()
    .byte(OP.PUSH_STR).str("0").byte(OP.STORE_VAR).str("c")
    .byte(OP.PUSH_SELECTOR).str("#b").byte(OP.GET_NODES).onEvent("click", "inc")
    .byte(OP.HALT)
    .label("inc")
    .byte(OP.INC).str("c")
    .byte(OP.PUSH_VAR).str("c")
    .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
    .byte(OP.HALT).finish();
  const [dj, dw] = makePair(["b", "out"]);
  bootBoth(f, "S4", prog, dj, dw);
  step(f, "S4 boot", dj, dw);
  fireBoth(dj, dw, "b", "click");
  step(f, "S4 click 1", dj, dw);
  expectEq(f, "S4 #out after 1 click", dj.nodes.out.textContent, "1");
  fireBoth(dj, dw, "b", "click");
  step(f, "S4 click 2", dj, dw);
  expectEq(f, "S4 #out after 2 clicks", dj.nodes.out.textContent, "2");
});

// 5. vector B: if/else both branches; branch value baked into the program
//    (the wasm VM exposes no state handle)
scenario("5: if/else both branches (vector B)", (f) => {
  const prog = (c) => new bc.Asm()
    .byte(OP.PUSH_STR).str(c).byte(OP.STORE_VAR).str("c")
    .byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES).onEvent("click", "h")
    .byte(OP.HALT)
    .label("h")
    .byte(OP.PUSH_VAR).str("c").byte(OP.PUSH_STR).str("1").byte(OP.CMP_EQ)
    .jif("els")
    .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("one")
    .jump("done")
    .label("els")
    .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("other")
    .label("done").byte(OP.HALT).finish();
  const [dj1, dw1] = makePair(["btn", "out"]);
  bootBoth(f, "S5 c=1", prog("1"), dj1, dw1);
  step(f, "S5 boot c=1", dj1, dw1);
  fireBoth(dj1, dw1, "btn", "click");
  step(f, "S5 click c=1", dj1, dw1);
  expectEq(f, "S5 #out c=1", dj1.nodes.out.textContent, "one");
  const [dj2, dw2] = makePair(["btn", "out"]);
  bootBoth(f, "S5 c=2", prog("2"), dj2, dw2);
  step(f, "S5 boot c=2", dj2, dw2);
  fireBoth(dj2, dw2, "btn", "click");
  step(f, "S5 click c=2", dj2, dw2);
  expectEq(f, "S5 #out c=2", dj2.nodes.out.textContent, "other");
});

// 6. while loop + extract_value + set_text(expr): #out gets the loop result,
//    #res gets input value + 1
scenario("6: while + extract_value + set_text(expr)", (f) => {
  const prog = new bc.Asm()
    .byte(OP.PUSH_STR).str("0").byte(OP.STORE_VAR).str("n")
    .byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES).onEvent("click", "w")
    .byte(OP.HALT)
    .label("w")
    .byte(OP.PUSH_VAR).str("n").byte(OP.PUSH_STR).str("3").byte(OP.CMP_LT)
    .jif("done")
    .byte(OP.INC).str("n")
    .jump("w")
    .label("done")
    .byte(OP.PUSH_VAR).str("n")
    .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
    .byte(OP.PUSH_SELECTOR).str("#inp").byte(OP.GET_NODES).byte(OP.EXTRACT_VALUE).str("v")
    .byte(OP.PUSH_VAR).str("v").byte(OP.PUSH_STR).str("1").byte(OP.ADD_NUM)
    .byte(OP.PUSH_SELECTOR).str("#res").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
    .byte(OP.HALT).finish();
  const [dj, dw] = makePair(["btn", "out", "res", "inp"], (a, b) => { a.nodes.inp.value = "7"; b.nodes.inp.value = "7"; });
  bootBoth(f, "S6", prog, dj, dw);
  step(f, "S6 boot", dj, dw);
  fireBoth(dj, dw, "btn", "click");
  step(f, "S6 click #btn", dj, dw);
  expectEq(f, "S6 #out (while result)", dj.nodes.out.textContent, "3");
  expectEq(f, "S6 #res (v+1)", dj.nodes.res.textContent, "8");
});

// 7. formatter alignment (§5.2): 0.1 + 0.2 must render the same decimal in
//    both engines
scenario("7: formatter alignment (0.1 + 0.2)", (f) => {
  const prog = new bc.Asm()
    .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).onEvent("load", "h").byte(OP.HALT)
    .label("h")
    .byte(OP.PUSH_STR).str("0.1").byte(OP.PUSH_STR).str("0.2").byte(OP.ADD_NUM)
    .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
    .byte(OP.HALT).finish();
  const [dj, dw] = makePair(["out"]);
  bootBoth(f, "S7", prog, dj, dw);
  step(f, "S7 boot", dj, dw);
  fireBoth(dj, dw, "out", "load");
  step(f, "S7 load #out", dj, dw);
  expectEq(f, "S7 #out (JS)", dj.nodes.out.textContent, "0.30000000000000004");
  expectEq(f, "S7 #out (WASM)", dw.nodes.out.textContent, "0.30000000000000004");
});

function main() {
  const jsSrc = fs.readFileSync(path.join(__dirname, "..", "src", "vm.js"), "utf8");
  const glueSrc = fs.readFileSync(path.join(__dirname, "..", "src", "wasm_glue.js"), "utf8");
  bootJs = new Function(jsSrc + "\n;return cairnBoot;")();
  bootWasm = new Function(glueSrc + "\n;return cairnBootWasm;")();
  wasmBytes = fs.readFileSync(path.join(__dirname, "..", "zig-out", "bin", "vm_wasm.wasm"));
  for (const [name, body] of scenarios) runScenario(name, body);
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exitCode = failed ? 1 : 0;
}

let bootJs, bootWasm, wasmBytes;
main();
