"use strict";
// Cairn WASM VM glue (v1.0): implements the 5 ABI imports over a doc.
// The VM's memory base is queried at runtime (mem_base); all pointers the VM
// passes to imports are absolute linear-memory addresses.
function cairnBootWasm(wasmBytes, bytecode, doc) {
  doc = doc || (typeof document !== "undefined" ? document : null);
  function vmError(code) {
    var names = ["ok", "StepLimitExceeded", "EventDepthExceeded", "UnknownOpcode", "NonNumeric"];
    var e = new Error("cairn-wasm: " + (names[code] || ("error " + code)));
    e.cairnCode = code;
    return e;
  }
  var handles = [];
  var pendingEvents = [];
  var dec = new TextDecoder();
  var enc = new TextEncoder();
  var instance;
  function readStr(ptr, len) { return dec.decode(new Uint8Array(instance.exports.memory.buffer, ptr, len)); }
  var imports = { env: {
    dom_query: function (ptr, len) {
      var sel = readStr(ptr, len);
      var nodes = doc.querySelectorAll(sel);
      handles.push(nodes);
      return handles.length - 1;
    },
    dom_apply_class: function (h, op, ptr, len) {
      var c = readStr(ptr, len);
      for (var k = 0; k < (handles[h] || []).length; k++) {
        var n = handles[h][k];
        if (op === 0) n.classList.add(c);
        else if (op === 1) n.classList.remove(c);
        else n.classList.toggle(c);
      }
    },
    dom_set_text: function (h, ptr, len) {
      var t = readStr(ptr, len);
      for (var k = 0; k < (handles[h] || []).length; k++) handles[h][k].textContent = t;
    },
    dom_get_text: function (h, op, destPtr, destCap) {
      var node = (handles[h] || [])[0];
      var s = node ? (op === 1 ? node.value : node.textContent) : "";
      var b = enc.encode(s).slice(0, destCap);
      new Uint8Array(instance.exports.memory.buffer, destPtr, b.length).set(b);
      return b.length;
    },
    dom_on: function (h, ptr, len, addr) {
      // deferred registration: arm the listener only after run_main returns 0,
      // so a mid-prologue failure cannot leak handlers into the JS fallback
      var ev = readStr(ptr, len);
      pendingEvents.push({ h: h, ev: ev, addr: addr });
    },
  } };
  // format prefix (spec §5.3): 0x00 0x01 = versioned stream; the JS VM skips it
  // at boot, so the wasm path must strip it before copying into linear memory —
  // otherwise opcode 0x00 hits ERR_OPCODE and the wasm backend silently falls back
  if (bytecode.length > 0 && bytecode[0] === 0) {
    if (bytecode.length < 2 || bytecode[1] !== 1) throw new Error("UnsupportedFormat");
    // slice, not subarray: with --debug-encoding the transport is a plain Array
    // (no subarray method); slice works for both Array and Uint8Array
    bytecode = bytecode.slice(2);
  }
  instance = new WebAssembly.Instance(new WebAssembly.Module(wasmBytes), imports);
  var base = instance.exports.mem_base();
  if (bytecode.length > 0x2000) throw new Error("cairn-wasm: bytecode exceeds the 8 KiB wasm region");
  new Uint8Array(instance.exports.memory.buffer).set(bytecode, base + 0x1000);
  var err = instance.exports.run_main(bytecode.length);
  if (err !== 0) throw vmError(err);
  // run_main succeeded: arm all deferred listeners
  for (var p = 0; p < pendingEvents.length; p++) {
    (function (ev, addr, nodes, h) { // deviation from plan: capture h (spec §9.3)
      for (var k = 0; k < nodes.length; k++) {
        nodes[k].addEventListener(ev, function () {
          instance.exports.set_cur_sel(h); // §9.3: handler argument passing
          var e2 = instance.exports.run_at(addr);
          if (e2 !== 0) console.error("cairn-wasm: " + e2);
        });
      }
    })(pendingEvents[p].ev, pendingEvents[p].addr, handles[pendingEvents[p].h] || [], pendingEvents[p].h);
  }
  return { err: err, instance: instance };
}
