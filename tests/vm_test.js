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

  // 11. top-level let + inc counter (G1: state machine)
  {
    const d = fresh();
    const asm = new bc.Asm()
      .byte(OP.PUSH_STR).str("0").byte(OP.STORE_VAR).str("c")
      .byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES).onEvent("click", "inc")
      .byte(OP.HALT)
      .label("inc").byte(OP.INC).str("c").byte(OP.HALT);
    const vm = boot(asm.finish(), d);
    eq(vm.state.c, "0", "let c = 0 initialized");
    d.nodes.btn.fire("click");
    eq(vm.state.c, "1", "inc c -> 1");
    d.nodes.btn.fire("click");
    eq(vm.state.c, "2", "inc c -> 2");
  }

  // 12. ADD_NUM hybrid: numeric sum vs concat (G1)
  {
    const d = fresh();
    const asm = new bc.Asm()
      .byte(OP.PUSH_STR).str("5").byte(OP.PUSH_STR).str("5").byte(OP.ADD_NUM)
      .byte(OP.STORE_VAR).str("n")
      .byte(OP.PUSH_STR).str("a").byte(OP.PUSH_STR).str("b").byte(OP.ADD_NUM)
      .byte(OP.STORE_VAR).str("s")
      .byte(OP.PUSH_STR).str("a").byte(OP.PUSH_STR).str("1").byte(OP.ADD_NUM)
      .byte(OP.STORE_VAR).str("m");
    const vm = boot(asm.finish(), d);
    eq(vm.state.n, "10", "5 + 5 -> 10");
    eq(vm.state.s, "ab", "a + b -> concat");
    eq(vm.state.m, "a1", "a + 1 -> concat");
  }

  // 13. SUB_NUM numeric only; non-numeric throws NonNumeric
  {
    const d = fresh();
    const vm = boot(new bc.Asm().byte(OP.PUSH_STR).str("7").byte(OP.PUSH_STR).str("2").byte(OP.SUB_NUM)
      .byte(OP.STORE_VAR).str("r").finish(), d);
    eq(vm.state.r, "5", "SUB_NUM 7 - 2 -> 5");
    let threw = null;
    try { boot(new bc.Asm().byte(OP.PUSH_STR).str("a").byte(OP.PUSH_STR).str("2").byte(OP.SUB_NUM).finish(), d); }
    catch (e) { threw = e.message; }
    eq(threw, "NonNumeric", "SUB_NUM on non-numeric throws");
  }

  // 14. numeric-aware comparisons (G1: "05" == "5" and "5" == "5.0" are true)
  {
    const d = fresh();
    function cmpEq(a, b) {
      const vm = boot(new bc.Asm()
        .byte(OP.PUSH_STR).str(a).byte(OP.PUSH_STR).str(b).byte(OP.CMP_EQ)
        .byte(OP.STORE_VAR).str("r").finish(), d);
      return vm.state.r;
    }
    eq(cmpEq("05", "5"), true, 'CMP_EQ "05" == "5"');
    eq(cmpEq("5", "5.0"), true, 'CMP_EQ "5" == "5.0"');
    eq(cmpEq("5", "05.1"), false, 'CMP_EQ "5" == "05.1"');
    eq(cmpEq("abc", "abc"), true, 'CMP_EQ string equality');
    eq(cmpEq("abc", "abd"), false, 'CMP_EQ string inequality');
    const vm = boot(new bc.Asm()
      .byte(OP.PUSH_STR).str("3").byte(OP.PUSH_STR).str("10").byte(OP.CMP_LT)
      .byte(OP.STORE_VAR).str("r").finish(), d);
    eq(vm.state.r, true, "CMP_LT 3 < 10 numeric");
    function cmpOp(opcode, a, b) {
      const vm = boot(new bc.Asm()
        .byte(OP.PUSH_STR).str(a).byte(OP.PUSH_STR).str(b).byte(opcode)
        .byte(OP.STORE_VAR).str("r").finish(), d);
      return vm.state.r;
    }
    eq(cmpOp(OP.CMP_GT, "10", "3"), true, "CMP_GT 10 > 3 numeric");
    eq(cmpOp(OP.CMP_GT, "3", "10"), false, "CMP_GT 3 > 10 numeric false");
    eq(cmpOp(OP.CMP_LE, "5", "5"), true, "CMP_LE 5 <= 5");
    eq(cmpOp(OP.CMP_GE, "5.0", "5"), true, "CMP_GE 5.0 >= 5 numeric");
    eq(cmpOp(OP.CMP_NE, "a", "b"), true, "CMP_NE string inequality");
    eq(cmpOp(OP.CMP_NE, "05", "5"), false, "CMP_NE numeric-aware");
  }

  // 15. formatter alignment: no exponent, -0 -> "0"
  {
    const d = fresh();
    function fmt(x) {
      const vm = boot(new bc.Asm()
        .byte(OP.PUSH_STR).str(x).byte(OP.PUSH_STR).str("0").byte(OP.ADD_NUM)
        .byte(OP.STORE_VAR).str("r").finish(), d);
      return vm.state.r;
    }
    eq(fmt("1000000000000000000000"), "1000000000000000000000", "1e21 round-trips in decimal");
    eq(fmt("0.0000001"), "0.0000001", "1e-7 round-trips in decimal");
  }
  {
    // numToStr is exported on the VM handle for direct unit testing
    const vm = boot([10], fresh());
    eq(vm.numToStr(0.1 + 0.2), "0.30000000000000004", "0.1+0.2 alignment");
    eq(vm.numToStr(1e21), "1000000000000000000000", "1e21 expansion");
    eq(vm.numToStr(1e-7), "0.0000001", "1e-7 expansion");
    eq(vm.numToStr(-0), "0", "-0 -> 0");
  }

  // 16. while loop terminates; infinite loop trips StepLimitExceeded (G1)
  {
    const d = fresh();
    const asm = new bc.Asm()
      .byte(OP.PUSH_STR).str("0").byte(OP.STORE_VAR).str("n") // let n = 0
      .byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES).onEvent("click", "w")
      .byte(OP.HALT)
      .label("w")
      .byte(OP.PUSH_VAR).str("n").byte(OP.PUSH_STR).str("3").byte(OP.CMP_LT)
      .jif("done")
      .byte(OP.INC).str("n")
      .jump("w")
      .label("done").byte(OP.HALT);
    const vm = boot(asm.finish(), d);
    d.nodes.btn.fire("click");
    eq(vm.state.n, "3", "while n < 3 { inc n } terminates with n=3");
  }
  {
    const d = fresh();
    const asm = new bc.Asm().label("top").jif("top").byte(OP.HALT);
    let threw = null;
    try { boot(asm.finish(), d); } catch (e) { threw = e.message; }
    eq(threw, "StepLimitExceeded", "infinite loop trips step budget");
  }

  // 17. if/else branch selection (G1: else branch)
  {
    const d = fresh();
    const asm = new bc.Asm()
      .byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES).onEvent("click", "h")
      .byte(OP.HALT)
      .label("h")
      .byte(OP.PUSH_VAR).str("c").byte(OP.PUSH_STR).str("1").byte(OP.CMP_EQ)
      .jif("els")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("one")
      .jump("done")
      .label("els")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("other")
      .label("done").byte(OP.HALT);
    const vm = boot(asm.finish(), d);
    vm.state.c = "1";
    d.nodes.btn.fire("click");
    eq(d.nodes.out.textContent, "one", "if branch taken");
    vm.state.c = "2";
    d.nodes.btn.fire("click");
    eq(d.nodes.out.textContent, "other", "else branch taken");
  }

  // 18. set_text (expr) via SET_TEXT_POP and extract_value (G1)
  {
    const d = fresh();
    d.nodes.inp = new MockNode("inp"); d.nodes.inp.value = "7";
    const asm = new bc.Asm()
      .byte(OP.PUSH_SELECTOR).str("#btn").byte(OP.GET_NODES).onEvent("click", "h")
      .byte(OP.HALT)
      .label("h")
      .byte(OP.PUSH_SELECTOR).str("#inp").byte(OP.GET_NODES).byte(OP.EXTRACT_VALUE).str("v")
      .byte(OP.PUSH_VAR).str("v").byte(OP.PUSH_STR).str("1").byte(OP.ADD_NUM)
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT_POP)
      .byte(OP.HALT);
    boot(asm.finish(), d);
    d.nodes.btn.fire("click");
    eq(d.nodes.out.textContent, "8", "extract_value + set_text(expr) -> 8");
  }

  // 19. JMP_IF_TRUE jumps when true, falls through when false
  {
    const d = fresh();
    const asm = new bc.Asm()
      .byte(OP.PUSH_STR).str("").byte(OP.PUSH_STR).str("").byte(OP.CMP_EQ)
      .byte(OP.JMP_IF_TRUE).ref16("skip")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("bad")
      .label("skip").byte(OP.HALT);
    boot(asm.finish(), d);
    eq(d.nodes.out.textContent, "", "JMP_IF_TRUE skips when true");
  }
  {
    const d = fresh();
    const asm = new bc.Asm()
      .byte(OP.PUSH_STR).str("a").byte(OP.PUSH_STR).str("b").byte(OP.CMP_EQ)
      .byte(OP.JMP_IF_TRUE).ref16("skip")
      .byte(OP.PUSH_SELECTOR).str("#out").byte(OP.GET_NODES).byte(OP.SET_TEXT).str("ok")
      .label("skip").byte(OP.HALT);
    boot(asm.finish(), d);
    eq(d.nodes.out.textContent, "ok", "JMP_IF_TRUE falls through when false");
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exitCode = failed ? 1 : 0;
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
