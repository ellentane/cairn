#!/usr/bin/env node
// The Last Box v2 smoke suite — permanent behavioral contract for the
// showcase page (example/index.md built by the e2e gate).
// Runs the compiled cairnBoot bytecode against a DOM mock and verifies
// the v2 contract: the action clock (every put/take/reject/drawer-open
// costs a minute from 5:14), the box-fill layers, the over-limit reject,
// the drawer beat, dusk/dark/gone room classes, the time-keyed seal
// endings (spare / dusk / dark / missed-train), the note-left variants
// (unread vs opened-but-left), the empty-box branch, and hover/focus
// lighting.
// Usage: node tests/showcase_smoke.js [path-to-built-page]
//   (defaults to index.html in the repo root)
"use strict";
const fs = require("fs");
const src = fs.readFileSync("src/vm.js", "utf8");
const boot = new Function(src + "\n;return cairnBoot;")();
function MockClassList(node) { this.node = node; this.set = new Set(); }
MockClassList.prototype.add = function (c) { this.set.add(c); };
MockClassList.prototype.remove = function (c) { this.set.delete(c); };
MockClassList.prototype.toggle = function (c) { this.set.has(c) ? this.set.delete(c) : this.set.add(c); };
MockClassList.prototype.has = function (c) { return this.set.has(c); };
function MockNode(id) {
  this.id = id; this._text = ""; this.value = ""; this.handlers = {};
  this.classList = new MockClassList(this);
  Object.defineProperty(this, "textContent", { get: () => this._text, set: (v) => { this._text = v; } });
}
MockNode.prototype.addEventListener = function (ev, fn) { (this.handlers[ev] = this.handlers[ev] || []).push(fn); };
MockNode.prototype.fire = function (ev) { for (const fn of this.handlers[ev] || []) fn(); };
function MockDoc() { this.nodes = {}; }
MockDoc.prototype.add = function (n) { this.nodes[n.id] = n; };
MockDoc.prototype.querySelectorAll = function (sel) {
  const out = [];
  if (sel.startsWith("#")) { const k = sel.slice(1); if (this.nodes[k]) out.push(this.nodes[k]); }
  return out;
};
function fresh(html) {
  const m = /cairnBoot\(Uint8Array.from\(atob\(\"([^\"]+)\"/.exec(html);
  const prog = [...Buffer.from(m[1], "base64")];
  const d = new MockDoc();
  for (const id of ["room","win","clock","story","box","total","left","nameline","name","fb","seal","ending","e-time","e-l1","e-stay","e-l2","e-name","e-mug","e-coat","e-notebook","e-cassette","e-photo","e-note","e-note-left","e-final","zero","one","scratch","w-mug","w-coat","w-notebook","w-cassette","w-photo","w-note","mem-mug","mem-coat","mem-notebook","mem-cassette","mem-photo","mem-note","mug-btn","coat-btn","notebook-btn","cassette-btn","photo-btn","note-btn","drawer-btn","row-mug","row-coat","row-notebook","row-cassette","row-photo","row-note","note-row","fill-mug","fill-coat","fill-notebook","fill-cassette","fill-photo","fill-note"]) d.add(new MockNode(id));
  d.nodes["zero"]._text = "0"; d.nodes["one"]._text = "1";
  d.nodes["w-mug"]._text = "400"; d.nodes["w-coat"]._text = "1800"; d.nodes["w-notebook"]._text = "700";
  d.nodes["w-cassette"]._text = "1200"; d.nodes["w-photo"]._text = "100"; d.nodes["w-note"]._text = "0";
  d.nodes["mem-mug"]._text = "mem-mug"; d.nodes["mem-coat"]._text = "mem-coat"; d.nodes["mem-notebook"]._text = "mem-notebook";
  d.nodes["mem-cassette"]._text = "mem-cassette"; d.nodes["mem-photo"]._text = "mem-photo"; d.nodes["mem-note"]._text = "mem-note";
  d.nodes.clock._text = "5:14";
  d.nodes["note-row"].classList.add("off");
  boot(prog, d);
  return d;
}
const html = fs.readFileSync(process.argv[2] || "index.html", "utf8");
let fail = 0;
function eq(actual, expected, msg) {
  if (actual === expected) { console.log("PASS " + msg); }
  else { fail++; console.error("FAIL " + msg + ": got " + JSON.stringify(actual) + " expected " + JSON.stringify(expected)); }
}
// clock ticks on a put
let d = fresh(html);
eq(d.nodes.clock.textContent, "5:14", "clock starts 5:14");
d.nodes["mug-btn"].fire("click");
eq(d.nodes.total.textContent, "400", "mug -> 400 g");
eq(d.nodes.clock.textContent, "5:15", "put costs a minute");
eq(d.nodes["fill-mug"].classList.has("on"), true, "box layer lights");
eq(d.nodes.room.classList.has("dusk"), false, "no dusk yet at 5:15");
// rejection costs a minute too
d = fresh(html);
d.nodes["coat-btn"].fire("click");
d.nodes["cassette-btn"].fire("click");
eq(d.nodes.total.textContent, "3000", "coat+cassette = 3000");
d.nodes["mug-btn"].fire("click");
eq(d.nodes.fb.textContent, "the box won't close. something has to come out.", "over-limit rejected");
eq(d.nodes.clock.textContent, "5:17", "three actions, 5:17");
eq(d.nodes.total.textContent, "3000", "total untouched");
// dusk at 25
d = fresh(html);
for (let i = 0; i < 11; i++) d.nodes["mug-btn"].fire("click");
eq(d.nodes.clock.textContent, "5:25", "11 actions -> 5:25");
eq(d.nodes.room.classList.has("dusk"), true, "dusk at 5:25");
// gone at 42 + stay-the-night ending
d = fresh(html);
for (let i = 0; i < 29; i++) d.nodes["mug-btn"].fire("click");
eq(d.nodes.clock.textContent, "5:43", "29 actions -> 5:43");
eq(d.nodes.room.classList.has("gone"), true, "gone at 5:43");
d.nodes.name.value = "ada";
d.nodes["seal"].fire("click");
eq(d.nodes["e-time"].textContent, "5:43.", "seal time printed");
eq(d.nodes["e-l1"].textContent, "the train is gone. you stay the night.", "stay-the-night line");
eq(d.nodes["e-stay"].textContent, "you unpack. the box can wait until tomorrow. the room is not empty tonight.", "stay line");
eq(d.nodes["e-final"].textContent, "", "no final line at >= 42");
// drawer beat: note row hidden until opened
d = fresh(html);
eq(d.nodes["note-row"].classList.has("off"), true, "note row hidden");
d.nodes["drawer-btn"].fire("click");
eq(d.nodes["note-row"].classList.has("off"), false, "drawer reveals the note");
eq(d.nodes.clock.textContent, "5:15", "drawer costs a minute");
eq(d.nodes.story.textContent, "the drawer is open. the note is inside.", "drawer story line");
// note-unread variant (drawer never opened)
d = fresh(html);
d.nodes["mug-btn"].fire("click");
d.nodes.name.value = "ada";
d.nodes["seal"].fire("click");
eq(d.nodes["e-note-left"].textContent, "the note stays in the drawer, unread.", "unread variant");
// opened-but-left variant
d = fresh(html);
d.nodes["drawer-btn"].fire("click");
d.nodes["mug-btn"].fire("click");
d.nodes.name.value = "ada";
d.nodes["seal"].fire("click");
eq(d.nodes["e-note-left"].textContent, "the note stays in the drawer. someone else will find it.", "opened variant");
// fast seal endings by time
d = fresh(html);
d.nodes["mug-btn"].fire("click");
d.nodes.name.value = "ada";
d.nodes["seal"].fire("click");
eq(d.nodes["e-time"].textContent, "5:15.", "fast seal time");
eq(d.nodes["e-l1"].textContent, "you made it with time to spare.", "spare line");
eq(d.nodes["e-final"].textContent, "the room is empty. it was a good room. someone else will say that, too.", "ending B (note unread)");
// ramp endings
d = fresh(html);
for (let i = 0; i < 16; i++) d.nodes["mug-btn"].fire("click"); // 5:30
d.nodes.name.value = "ada";
d.nodes["seal"].fire("click");
eq(d.nodes["e-l1"].textContent, "you made it. the light outside is going.", "dusk ramp line");
d = fresh(html);
for (let i = 0; i < 26; i++) d.nodes["mug-btn"].fire("click"); // 5:40
d.nodes.name.value = "ada";
d.nodes["seal"].fire("click");
eq(d.nodes["e-l1"].textContent, "you ran the last stretch.", "dark ramp line");
// lid appears only when sealed
d = fresh(html);
d.nodes["mug-btn"].fire("click");
d.nodes.name.value = "ada";
d.nodes["seal"].fire("click");
eq(d.nodes.box.classList.has("sealed"), true, "box sealed below 42");
eq(d.nodes["seal"].textContent, "sealed", "seal button text");
d = fresh(html);
for (let i = 0; i < 29; i++) d.nodes["mug-btn"].fire("click");
eq(d.nodes.box.classList.has("sealed"), false, "box unsealed past 42");
d.nodes.name.value = "ada";
d.nodes["seal"].fire("click");
eq(d.nodes["seal"].textContent, "the train is gone", "button tells the truth");
// name required + empty box
d = fresh(html);
d.nodes["seal"].fire("click");
eq(d.nodes.fb.textContent, "write your name on the label first.", "name required");
d.nodes.name.value = "ada";
d.nodes["seal"].fire("click");
eq(d.nodes["e-l2"].textContent, "you seal the empty box. there was nothing to take.", "empty box line");
// hover + focus
d = fresh(html);
d.nodes["row-mug"].fire("mouseenter");
eq(d.nodes["row-mug"].classList.has("lit"), true, "row catches the light");
d.nodes.name.fire("focus");
eq(d.nodes.nameline.classList.has("glow"), true, "label glows");
d.nodes.name.fire("blur");
eq(d.nodes.nameline.classList.has("glow"), false, "glow off");
console.log(fail ? `\n${fail} FAILURE(S)` : "\nALL LASTBOX V2 SMOKE CHECKS PASS");
process.exitCode = fail ? 1 : 0;
