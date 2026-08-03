"use strict";
// Cairn Bytecode VM v0.1 — ES6+, zero dependencies.
// Format contract: docs/superpowers/specs/2026-08-02-cairn-v1-design.md §5.
function cairnBoot(bytes, doc) {
  doc = doc || (typeof document !== "undefined" ? document : null);
  var B = Uint8Array.from(bytes);
  var S = [];
  var st = Object.create(null);
  var ip = 0;
  var depth = 0;
  var steps = 0;
  var MAX_DEPTH = 32;
  var MAX_STEPS = 1000000;

  if (B.length > 0 && B[0] === 0) {
    if (B.length < 2 || B[1] !== 1) throw new Error("UnsupportedFormat");
    ip = 2;
  }

  function u16() { var v = B[ip] | (B[ip + 1] << 8); ip += 2; return v; }
  function top() { return S[S.length - 1]; }
  function str() {
    var n = u16();
    var s = new TextDecoder().decode(B.subarray(ip, ip + n));
    ip += n;
    return s;
  }
  function each(nodes, fn) { for (var k = 0; k < nodes.length; k++) fn(nodes[k]); }
  function addClass(n, c) { each(n, function(e) { e.classList.add(c); }); }
  function removeClass(n, c) { each(n, function(e) { e.classList.remove(c); }); }
  function toggleClass(n, c) { each(n, function(e) { e.classList.toggle(c); }); }
  function setText(n, c) { each(n, function(e) { e.textContent = c; }); }
  function extractText(n, v) { st[v] = n.length ? n[0].textContent : ""; }

  var RE_NUM = /^-?\d+(\.\d+)?$/;
  function isNum(s) { return RE_NUM.test(s); }
  function expandExp(s) {
    var m = /^(-?)(\d+)(?:\.(\d+))?e([+-]?\d+)$/.exec(s);
    if (!m) return s;
    var digits = m[2] + (m[3] || "");
    var point = m[2].length + Number(m[4]);
    if (point <= 0) return m[1] + "0." + "0".repeat(-point) + digits;
    if (point >= digits.length) return m[1] + digits + "0".repeat(point - digits.length);
    return m[1] + digits.slice(0, point) + "." + digits.slice(point);
  }
  function numToStr(x) {
    var s = String(x);
    return s.indexOf("e") >= 0 ? expandExp(s) : s;
  }
  function bothNum(a, b) { return isNum(a) && isNum(b); }
  function cmp(op, a, b) {
    switch (op) {
      case 19: return bothNum(a, b) ? Number(a) === Number(b) : a === b;          // CMP_EQ
      case 20: return !(bothNum(a, b) ? Number(a) === Number(b) : a === b);       // CMP_NE
      case 21: return bothNum(a, b) ? Number(a) < Number(b) : a < b;              // CMP_LT
      case 22: return bothNum(a, b) ? Number(a) > Number(b) : a > b;              // CMP_GT
      case 23: return bothNum(a, b) ? Number(a) <= Number(b) : a <= b;            // CMP_LE
      case 24: return bothNum(a, b) ? Number(a) >= Number(b) : a >= b;            // CMP_GE
    }
  }

  function run() {
    if (++depth > MAX_DEPTH) throw new Error("EventDepthExceeded");
    var baseSteps = steps;
    steps = 0;
    try {
      while (ip < B.length) {
        if (++steps > MAX_STEPS) throw new Error("StepLimitExceeded");
        var op = B[ip++];
        switch (op) {
          case 1: S.push(str()); break;                              // PUSH_STR
          case 2: S.push(str()); break;                              // PUSH_SELECTOR
          case 3: S.push(doc.querySelectorAll(S.pop())); break;      // GET_NODES
          case 4: addClass(top(), str()); break;                   // ADD_CLASS (leaves nodes on stack)
          case 5: removeClass(top(), str()); break;                // REMOVE_CLASS (leaves nodes on stack)
          case 6: toggleClass(top(), str()); break;                // TOGGLE_CLASS (leaves nodes on stack)
          case 7: setText(S.pop(), str()); break;                    // SET_TEXT
          case 8: bindEvent(S.pop(), str(), u16()); break;           // ON_EVENT
          case 9: ip = u16(); break;                                 // JUMP
          case 10: return;                                           // HALT
          case 11: extractText(S.pop(), str()); break;               // EXTRACT_TEXT
          case 12: S.push(st[str()] || ""); break;                   // PUSH_VAR
          case 13: { var b = S.pop(), a = S.pop(); S.push(a === b); break; } // CMP_STR
          case 14: { var t = u16(); if (!S.pop()) ip = t; break; }   // JMP_IF_FALSE
          case 15: { var v = str(); st[v] = S.pop(); break; }                      // STORE_VAR
          case 16: { var v = str(); if (!isNum(st[v])) throw new Error("NonNumeric");
                     st[v] = numToStr(Number(st[v]) + 1); break; }                 // INC
          case 17: { var b = S.pop(), a = S.pop(); S.push(bothNum(a, b) ? numToStr(Number(a) + Number(b)) : a + b); break; } // ADD_NUM
          case 18: { var b = S.pop(), a = S.pop(); if (!bothNum(a, b)) throw new Error("NonNumeric");
                     S.push(numToStr(Number(a) - Number(b))); break; }             // SUB_NUM
          case 19: case 20: case 21: case 22: case 23: case 24:
                   { var b = S.pop(), a = S.pop(); S.push(cmp(op, a, b)); break; } // CMP family
          case 25: { var t = u16(); if (S.pop()) ip = t; break; }                  // JMP_IF_TRUE
          case 26: { var n = S.pop(); setText(n, S.pop()); break; }                // SET_TEXT_POP
          case 27: { var v = str(); var n = S.pop(); st[v] = n.length ? n[0].value : ""; break; } // EXTRACT_VALUE
          default: throw new Error("UnknownOpcode 0x" + op.toString(16) + " @ " + (ip - 1));
        }
      }
    } finally {
      depth--;
      steps = baseSteps;
    }
  }
  function bindEvent(nodes, ev, addr) {
    each(nodes, function(e) {
      e.addEventListener(ev, function() {
        var savedIp = ip;
        var savedStack = S.slice();
        S.length = 0;
        S.push(nodes); // handler's argument: its own NodeList
        try { ip = addr; run(); }
        catch (err) { console.error("cairn: " + err.message); throw err; }
        finally { ip = savedIp; S = savedStack; }
      });
    });
  }
  try { run(); }
  catch (err) { console.error("cairn: " + err.message); throw err; }
  return { state: st, numToStr: numToStr, isNum: isNum };
}

if (typeof document !== "undefined") {
  var go = function() { cairnBoot(__CAIRN_BYTES__); };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go);
  else go();
}
