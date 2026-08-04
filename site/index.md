# Cairn

A hermetic static site generator: Markdown plus a tiny event DSL compile into
one self-contained `index.html` — an embedded bytecode VM, zero external
requests.

This page is itself a Cairn build. Try it:

<button id="count">Count</button>
<p id="out">0</p>

```cairn
let n = 0;
on click "#count" {
    inc n;
    if n == "5" {
        set_text "five!" on "#out";
    } else {
        set_text n on "#out";
    }
}
```

## What's inside

- **Hermetic** — one file, no network requests (audited by `cairn verify` in CI)
- **A state machine DSL** — `let`, `inc`, expressions, `if`/`else`, `while`,
  text and input-value extraction
- **Size budgets and tiers** — fail builds over budget; every page gets a tier
  badge and a half-life score
- **Verified** — golden bytecode vectors, dual VM test suites, an end-to-end
  gate, and browser tests

## Live example

The [full showcase page](example.html) exercises every DSL feature end to end —
hover, counters, comparisons, input echo.

## Building

```bash
zig build
./zig-out/bin/cairn build example/index.md
```

## License

MIT.
