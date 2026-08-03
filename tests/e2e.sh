#!/usr/bin/env bash
# Cairn v0.1 end-to-end gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== zig build test =="
zig build test

echo "== fixture validator =="
node tests/fixture_check.js

echo "== VM behavior suite =="
node tests/vm_test.js

echo "== build example =="
./zig-out/bin/cairn build example/index.md >/dev/null 2> /tmp/opencode/cairn-report.txt
cat /tmp/opencode/cairn-report.txt

echo "== VM behavior on built page =="
node tests/vm_test.js --from-file index.html

echo "== fixture round-trip: CLI output must match hand-authored .bin =="
mkdir -p /tmp/opencode/fixtures
for name in V1 V2 V3; do
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
  if diff <(tr -d ' ' < "tests/fixtures/v0.1/$name.bin") \
          <(tr -d ' ' < "/tmp/opencode/fixtures/$name.got.bin") > /dev/null; then
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

echo
echo "E2E GATE GREEN"
