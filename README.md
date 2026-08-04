# Cairn

A hermetic static site generator in Zig. Markdown plus a tiny event DSL compile
into **one self-contained `index.html`**: an embedded bytecode VM drives page
interactivity with zero external requests, no frameworks, no network.

```bash
zig build
./zig-out/bin/cairn build example/index.md   # -> index.html
```

## The idea

`cairn build` renders your Markdown, compiles the `cairn` fence into bytecode,
and embeds a small JS VM that executes it — all in a single file you can email,
archive, or open from a USB stick. The bytecode format is pinned by golden
vectors and versioned; the fixture corpus is the contract between the Zig
compiler and the VM.

A page script:

````markdown
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
````

Build `example/index.md` and open it: **The Last Box**, a four-minute story
about leaving, running entirely as one file.

## Features

- **Hermetic by construction** — `cairn verify` audits built pages for external
  references; CI runs it on every build.
- **State machine DSL** — `let`, `inc`, `+`/`-` expressions, `if`/`else`,
  `while`, text and input-value extraction, 11 event types.
- **Size budgets and tiers** — `--budget NKB` fails the build; every page gets
  a tier badge (Tombstone < 4 KB, Monolith < 16 KB, Obelisk < 64 KB, Megalith
  beyond) and a half-life score.
- **Multi-file sites** — `cairn build <dir>` merges pages (`ORDER` file or
  filename order).
- **Markdown** — headings, lists, tables, blockquotes, code fences with
  language tags, hermetic image inlining (local files become data URIs),
  `cairn-css` blocks.
- **Verified** — golden bytecode vectors, dual VM suites (source + minified),
  an end-to-end gate script, and Playwright browser tests in CI.

## Commands

```
cairn build <file.md | dir> [--output <path>] [--budget <NKB>] [--debug-encoding]
cairn verify <index.html>       # hermeticity audit
cairn demo [dir]                # generate + build a sample site
cairn fixtures <dir>            # regenerate the fixture corpus
```

## Requirements

- Zig 0.16.0 (`zig build`)
- Node 22+ (dev only: test suites, Playwright)

## Milestones

| Tag | What landed |
|---|---|
| `v0.1` | Pipeline, DSL basics, embedded VM, golden fixtures, e2e gate |
| `v0.2` | State machine, numeric coercion, `cairn fixtures`, corpus + coverage |
| `v0.3` | Markdown expansion, base64 transport, dir builds, budgets, `verify`, minified VM, Playwright CI |
| `v1.0` (planned) | WASM VM backend, audio FSK relay, tiers hardened |

## License

MIT — see [LICENSE](LICENSE).
