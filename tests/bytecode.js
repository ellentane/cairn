"use strict";
// Shared cairn bytecode tooling (v0.1): used by vm_test.js and fixture_check.js.
const OPCODES = { PUSH_STR:1, PUSH_SELECTOR:2, GET_NODES:3, ADD_CLASS:4, REMOVE_CLASS:5,
  TOGGLE_CLASS:6, SET_TEXT:7, ON_EVENT:8, JUMP:9, HALT:10, EXTRACT_TEXT:11, PUSH_VAR:12,
  CMP_STR:13, JMP_IF_FALSE:14,
  STORE_VAR:15, INC:16, ADD_NUM:17, SUB_NUM:18, CMP_EQ:19, CMP_NE:20,
  CMP_LT:21, CMP_GT:22, CMP_LE:23, CMP_GE:24, JMP_IF_TRUE:25, SET_TEXT_POP:26,
  EXTRACT_VALUE:27 };
const NAMES = {};
for (const k in OPCODES) NAMES[OPCODES[k]] = k;
const PAYLOAD = { 1:"str", 2:"str", 4:"str", 5:"str", 6:"str", 7:"str", 8:"str+addr",
  9:"addr", 11:"str", 12:"str", 14:"addr", 15:"str", 16:"str", 25:"addr", 27:"str" };

function strAt(bytes, i) {
  if (i + 2 > bytes.length) throw new Error("truncated bytecode @" + i);
  const n = bytes[i] | (bytes[i + 1] << 8);
  if (i + 2 + n > bytes.length) throw new Error("truncated string @" + i);
  return { s: new TextDecoder().decode(bytes.subarray(i + 2, i + 2 + n)), next: i + 2 + n };
}
function addrAt(bytes, i) {
  if (i + 2 > bytes.length) throw new Error("truncated bytecode @" + i);
  return { a: bytes[i] | (bytes[i + 1] << 8), next: i + 2 };
}
function decode(bytes) {
  const ins = [];
  let i = 0;
  while (i < bytes.length) {
    const pos = i;
    const op = bytes[i++];
    const name = NAMES[op];
    if (!name) throw new Error("UnknownOpcode 0x" + op.toString(16) + " @ " + pos);
    switch (PAYLOAD[op]) {
      case "str": { const r = strAt(bytes, i); ins.push({ pos, op, name, s: r.s }); i = r.next; break; }
      case "addr": { const r = addrAt(bytes, i); ins.push({ pos, op, name, addr: r.a }); i = r.next; break; }
      case "str+addr": { const r1 = strAt(bytes, i); const r2 = addrAt(bytes, r1.next);
        ins.push({ pos, op, name, s: r1.s, addr: r2.a }); i = r2.next; break; }
      default: ins.push({ pos, op, name });
    }
  }
  return ins;
}
function encodeStr(out, s) {
  const b = new TextEncoder().encode(s);
  const n = b.length;
  out.push(n & 255, (n >> 8) & 255);
  for (let k = 0; k < n; k++) out.push(b[k]);
}
function parseBin(text) {
  return Uint8Array.from(text.split(",").map((x) => Number(x.trim())));
}
class Asm {
  constructor() { this.bc = []; this.patches = []; this.labels = {}; }
  byte(o) { this.bc.push(o); return this; }
  str(s) { encodeStr(this.bc, s); return this; }
  label(n) { this.labels[n] = this.bc.length; return this; }
  ref16(label) { this.patches.push([this.bc.length, label]); this.bc.push(0, 0); return this; }
  onEvent(evt, label) { this.bc.push(OPCODES.ON_EVENT); encodeStr(this.bc, evt); this.ref16(label); return this; }
  jif(label) { this.bc.push(OPCODES.JMP_IF_FALSE); this.ref16(label); return this; }
  jump(label) { this.bc.push(OPCODES.JUMP); this.ref16(label); return this; }
  finish() {
    for (const [pos, name] of this.patches) {
      const v = this.labels[name];
      if (v === undefined) throw new Error("undefined label: " + name);
      if (v > 0xFFFF) throw new Error("label too large: " + name);
      this.bc[pos] = v & 255;
      this.bc[pos + 1] = (v >> 8) & 255;
    }
    return this.bc;
  }
}
module.exports = { OPCODES, NAMES, PAYLOAD, strAt, addrAt, decode, encodeStr, parseBin, Asm };
