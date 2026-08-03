#!/usr/bin/env bash
# Cairn v0.1 end-to-end gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== build =="
zig build

echo "== zig build test =="
zig build test

echo "== fixture validator =="
node tests/fixture_check.js

echo "== v0.2 fixture validator (migration + coverage) =="
node tests/fixture_check.js v0.2

echo "== VM behavior suite =="
node tests/vm_test.js

echo "== minified VM behavior =="
node tests/vm_test.js --vm-file src/vm.min.js

echo "== build example =="
./zig-out/bin/cairn build example/index.md >/dev/null 2> /tmp/opencode/cairn-report.txt
cat /tmp/opencode/cairn-report.txt

echo "== VM behavior on built page =="
node tests/vm_test.js --from-file index.html

echo "== fixture round-trip: CLI output must match hand-authored .bin =="
mkdir -p /tmp/opencode/fixtures
# V3 is excluded: v0.2 compiles its `==` to CMP_EQ (19) where the v0.1
# fixture pins CMP_STR (13); the v0.1 corpus is immutable by policy and
# tests/fixtures/v0.2/migration.bin pins the migrated bytes instead.
for name in V1 V2; do
  ./zig-out/bin/cairn build "tests/fixtures/v0.1/$name.md" >/dev/null 2>&1
  # extract the bytecode literal from the built page (decimal or base64 transport)
  python3 - <<'PY' > /tmp/opencode/fixtures/$name.got.bin
import re, base64, sys
html = open("index.html").read()
m = re.search(r"cairnBoot\(Uint8Array.from\(atob\(\"([^\"]+)\"", html)
if m:
    print(",".join(str(b) for b in base64.b64decode(m.group(1))))
else:
    m = re.search(r"cairnBoot\(\s*\[\s*([\s\S]*?)\s*\]\s*\)", html)
    assert m, "no cairnBoot literal"
    print(re.sub(r"\s+", " ", m.group(1)))
PY
  if diff <(tr -d ' \n' < "tests/fixtures/v0.1/$name.bin") \
          <(tr -d ' \n' < "/tmp/opencode/fixtures/$name.got.bin") > /dev/null; then
    echo "PASS $name round-trip"
  else
    echo "FAIL $name round-trip: compiled bytecode differs from fixture" >&2
    exit 1
  fi
done

echo "== hermiticity spot-check (no external refs in output) =="
./zig-out/bin/cairn build example/index.md >/dev/null 2>&1
if grep -E "https?://|src=\"http|href=\"http" index.html | grep -v "data:image/svg"; then
  echo "FAIL: external references found" >&2
  exit 1
fi
echo "PASS no external references"

echo "== v0.2 gate: example interactions =="
node - <<'EOF'
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync("src/vm.js", "utf8");
const boot = new Function(src + "\n;return cairnBoot;")();
function MockClassList(){this.set=new Set()}
MockClassList.prototype.add=function(c){this.set.add(c)}; MockClassList.prototype.has=function(c){return this.set.has(c)};
function MockNode(id){this.id=id;this._text="";this.value="";this.classList=new MockClassList();this.handlers={};
  Object.defineProperty(this,"textContent",{get:()=>this._text,set:(v)=>{this._text=v}})}
MockNode.prototype.addEventListener=function(ev,fn){(this.handlers[ev]=this.handlers[ev]||[]).push(fn)};
MockNode.prototype.fire=function(ev){for(const fn of this.handlers[ev]||[])fn()};
function MockDoc(){this.nodes={}}
MockDoc.prototype.add=function(n){this.nodes[n.id]=n};
MockDoc.prototype.querySelectorAll=function(sel){const k=sel.slice(1);return this.nodes[k]?[this.nodes[k]]:[]};
const html = fs.readFileSync("index.html","utf8");
let prog = null;
let mb = /cairnBoot\(Uint8Array.from\(atob\(\"([^\"]+)\"/.exec(html);
if (mb) {
  prog = [...Buffer.from(mb[1], "base64")];
} else {
  const m = /cairnBoot\(\s*\[\s*([\s\S]*?)\s*\]\s*\)/.exec(html);
  if (m) prog = JSON.parse("[" + m[1].replace(/\s+/g," ") + "]");
}
if (!prog) { console.error("FAIL: no cairnBoot literal found"); process.exit(1); }
const d = new MockDoc();
for (const id of ["btn","out","chk","status","box","inc","count","name"]) d.add(new MockNode(id));
d.nodes.status.textContent = "pending";
d.nodes.name.value = "world";
boot(prog, d);
d.nodes.inc.fire("click");
if (d.nodes.out.textContent !== "1 clicks") { console.error("FAIL counter 1"); process.exit(1); }
d.nodes.inc.fire("click");
if (d.nodes.out.textContent !== "2 clicks") { console.error("FAIL counter 2"); process.exit(1); }
d.nodes.inc.fire("click");
if (d.nodes.out.textContent !== "three clicks!") { console.error("FAIL counter 3 (if branch)"); process.exit(1); }
d.nodes.name.fire("input");
if (d.nodes.out.textContent !== "hello world") { console.error("FAIL extract_value+concat"); process.exit(1); }
console.log("PASS example v0.2 interactions");
EOF

echo
echo "E2E GATE GREEN"
