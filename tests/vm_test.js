"use strict";
// Cairn VM behavior tests: zero-dep DOM shim + assembled programs.
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
  // Simulating DOM semantics for the depth-guard test: setting textContent
  // synchronously dispatches any registered "input" handlers.
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

let passed = 0, failed = 0;
function eq(actual, expected, msg) {
  if (actual === expected) { passed++; console.log("PASS " + msg); }
  else { failed++; console.error("FAIL " + msg + ": got " + JSON.stringify(actual) + " expected " + JSON.stringify(expected)); }
}

async function main() {
  const vmArg = process.argv.indexOf("--vm-file");
  const src = fs.readFileSync(vmArg >= 0 ? process.argv[vmArg + 1] : path.join(__dirname, "..", "src", "vm.js"), "utf8");
  const boot = new Function(src + "\n;return cairnBoot;")();

  function fresh() {
    const d = new MockDoc();
    for (const id of ["btn", "out", "a", "b", "go", "src", "dst", "e1", "e2"]) d.add(new MockNode(id));
    return d;
  }

  // 1. class ops apply to all matched nodes
  {
    const d = fresh();
    const asm = new bc.Asm().byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES).byte(OP.ADD_CLASS).str("active");
    boot(asm.finish(), d);
    eq(d.nodes.btn.classList.has("active"), true, "ADD_CLASS applied");
  }

  // 2. toggle
  {
    const d = fresh();
    const asm = new bc.Asm().byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES)
      .byte(OP.TOGGLE_CLASS).str("t").byte(OP.TOGGLE_CLASS).str("t");
    boot(asm.finish(), d);
    eq(d.nodes.btn.classList.has("t"), false, "TOGGLE_CLASS twice -> absent");
  }

  // 3. handler receives its own captured nodes (V2 cross-wire guard):
  //    handler bodies consume the stack argument directly, no re-query.
  //    Each block is terminated by a trailing HALT so handlers never run
  //    into the next block's code.
  {
    const d = fresh();
    const asm = new bc.Asm()
      .byte(OP.PUSH_SELECTOR).str("#a").byte(OP.GET_NODES).onEvent("click", "clickA")
      .byte(OP.PUSH_SELECTOR).str("#b").byte(OP.GET_NODES).onEvent("click", "clickB")
      .byte(OP.HALT)
      .label("clickA").byte(OP.SET_TEXT).str("A").byte(OP.HALT)
      .label("clickB").byte(OP.SET_TEXT).str("B").byte(OP.HALT);
    boot(asm.finish(), d);
    d.nodes.a.fire("click");
    eq(d.nodes.a.textContent, "A", "handler A wrote to #a via captured nodes");
    eq(d.nodes.b.textContent, "", "handler A did not run into handler B");
    d.nodes.b.fire("click");
    eq(d.nodes.b.textContent, "B", "handler B wrote to #b via captured nodes");
  }

  // 4. extract_text + if: matching and non-matching (V3 behavior);
  //    the if-skip target is the block's trailing HALT
  {
    const d = fresh();
    d.nodes.src.textContent = "yes";
    const asm = new bc.Asm()
      .byte(OP.PUSH_SELECTOR).str("#go").byte(OP.GET_NODES).onEvent("click", "go")
      .byte(OP.HALT)
      .label("go")
      .byte(OP.PUSH_SELECTOR).str("#src").byte(OP.GET_NODES).byte(OP.EXTRACT_TEXT).str("v")
      .byte(OP.PUSH_VAR).str("v").byte(OP.PUSH_STR).str("yes").byte(OP.CMP_STR)
      .jif("end")
      .byte(OP.PUSH_SELECTOR).str("#dst").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("hit")
      .label("end").byte(OP.HALT);
    boot(asm.finish(), d);
    d.nodes.go.fire("click");
    eq(d.nodes.dst.textContent, "hit", "if matched -> set_text ran");
    d.nodes.src.textContent = "no";
    d.nodes.dst.textContent = "";
    d.nodes.go.fire("click");
    eq(d.nodes.dst.textContent, "", "if not matched -> skipped to trailing HALT");
  }

  // 5. PUSH_VAR default ""
  {
    const d = fresh();
    const asm = new bc.Asm()
      .byte(OP.PUSH_VAR).str("nope").byte(OP.PUSH_STR).str("").byte(OP.CMP_STR)
      .jif("skip")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("default-ok")
      .label("skip").byte(OP.HALT);
    boot(asm.finish(), d);
    eq(d.nodes.out.textContent, "default-ok", "uninitialized var defaults to empty string");
  }

  // 6. step limit: infinite while loop throws StepLimitExceeded
  {
    const d = fresh();
    const asm = new bc.Asm().label("top").jif("top").byte(OP.HALT);
    // JMP_IF_FALSE pops from an empty stack -> undefined -> falsy -> infinite loop
    let threw = null;
    try { boot(asm.finish(), d); } catch (e) { threw = e.message; }
    eq(threw, "StepLimitExceeded", "infinite loop trips step budget");
  }

  // 7. recursion depth: set_text on a node with an input listener re-fires
  //    the event synchronously (mock DOM semantics) -> EventDepthExceeded
  {
    const d = fresh();
    const asm = new bc.Asm()
      .byte(OP.PUSH_SELECTOR).str("#e2").byte(OP.GET_NODES).onEvent("input", "h2")
      .byte(OP.HALT)
      .label("h2")
      .byte(OP.PUSH_SELECTOR).str("#e2").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("x");
    boot(asm.finish(), d);
    let threw = null;
    try { d.nodes.e2.fire("input"); } catch (e) { threw = e.message; }
    eq(threw, "EventDepthExceeded", "recursive DOM-triggered handlers trip depth guard");
  }

  // 8. versioned stream: 0x00 0x01 prefix boots; 0x00 0x02 throws
  {
    const d = fresh();
    const prog = [0, 1, 10]; // prefix v1 + HALT
    boot(prog, d); // must not throw
    passed++; console.log("PASS versioned stream (0x00 0x01) boots");
    let threw = null;
    try { boot([0, 2, 10], d); } catch (e) { threw = e.message; }
    eq(threw, "UnsupportedFormat", "unknown format version throws");
  }

  // 9. unknown opcode throws loudly
  {
    const d = fresh();
    let threw = null;
    try { boot([0x7F, 10], d); } catch (e) { threw = e.message; }
    eq(threw, "UnknownOpcode 0x7f @ 0", "unknown opcode throws");
  }

  // 10. --from-file mode: run the built example page (transport-aware: decimal or base64)
  const fromFileArg = process.argv.indexOf("--from-file");
  const fromFile = fromFileArg >= 0 ? process.argv[fromFileArg + 1] : null;
  if (fromFile) {
    const html = fs.readFileSync(fromFile, "utf8");
    let prog = null;
    let mb = /cairnBoot\(Uint8Array.from\(atob\(\"([^\"]+)\"/.exec(html);
    if (mb) {
      prog = [...Buffer.from(mb[1], "base64")];
    } else {
      const m = /cairnBoot\(\s*\[\s*([\s\S]*?)\s*\]\s*\)/.exec(html);
      if (m) prog = JSON.parse("[" + m[1].replace(/\s+/g, " ") + "]");
    }
    if (!prog) { failed++; console.error("FAIL --from-file: no cairnBoot literal found"); }
    else {
      const d = new MockDoc();
      for (const id of ["btn", "out", "chk", "status", "box"]) d.add(new MockNode(id));
      d.nodes.status.textContent = "pending";
      boot(prog, d);
      d.nodes.btn.fire("click");
      eq(d.nodes.out.textContent, "Status: 1", "example: click #btn -> #out text");
      d.nodes.box.fire("mouseenter");
      eq(d.nodes.box.classList.has("lit"), true, "example: hover (#box) -> mouseenter -> class");
      d.nodes.chk.fire("click");
      eq(d.nodes.status.textContent, "pending", "example: extract/if with non-matching value");
      d.nodes.status.textContent = "done";
      d.nodes.chk.fire("click");
      eq(d.nodes.status.textContent, "already done", "example: extract/if with matching value");
    }
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exitCode = failed ? 1 : 0;
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
