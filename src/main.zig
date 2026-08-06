const std = @import("std");
const markdown = @import("markdown.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const emitter = @import("emitter.zig");
const audio = @import("audio.zig");

// decode.html companion: template plus the inlined decoder source
// (src/decode.html.tpl is a symlink to tools/decode.html.tpl — Zig's
// @embedFile rejects "../" paths, so the link keeps the template canonical)
const decode_html_tpl = @embedFile("decode.html.tpl");
const decoder_js = @embedFile("decoder.js");

const max_input: usize = 1 << 20;

const Options = struct {
    output: []const u8 = "index.html",
    budget: ?usize = null,
    debug_encoding: bool = false,
    vm: emitter.Vm = .js,
    strict_format: bool = false,
    audio: ?[]const u8 = null,
    audio_profile: usize = 1,
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cairn: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print("usage: cairn build <input.md|dir> [--output <file>] [--audio <out.wav>] [--audio-profile clean|radio] [--budget <kb>] [--debug-encoding] [--vm js|wasm] [--strict-format] | cairn verify <file> | cairn demo [dir] | cairn fixtures <dir>\n", .{});
    std.process.exit(2);
}

fn printDiag(input_path: []const u8, source: []const u8, line_no: u32, col: u32, msg: []const u8) void {
    std.debug.print("error[{s}:{d}:{d}]: {s}\n", .{ input_path, line_no, col, msg });
    var lines = std.mem.splitScalar(u8, source, '\n');
    var i: u32 = 1;
    while (lines.next()) |line| : (i += 1) {
        if (i == line_no) {
            var tmp: [16]u8 = undefined;
            const gutter = std.fmt.bufPrint(&tmp, "  {d} | ", .{line_no}) catch unreachable;
            std.debug.print("{s}{s}\n", .{ gutter, line });
            std.debug.print("{s}", .{gutter});
            var c: u32 = 1;
            while (c < col) : (c += 1) std.debug.print(" ", .{});
            std.debug.print("^\n", .{});
            return;
        }
    }
}

fn parseFlags(_: std.mem.Allocator, args: []const [:0]const u8, start: usize) !Options {
    var opts = Options{};
    var i = start;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            opts.output = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--budget") and i + 1 < args.len) {
            opts.budget = std.fmt.parseUnsigned(usize, args[i + 1], 10) catch
                fatal("invalid --budget value: {s}", .{args[i + 1]});
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--debug-encoding")) {
            opts.debug_encoding = true;
        } else if (std.mem.eql(u8, args[i], "--vm") and i + 1 < args.len) {
            if (std.mem.eql(u8, args[i + 1], "js")) {
                opts.vm = .js;
            } else if (std.mem.eql(u8, args[i + 1], "wasm")) {
                opts.vm = .wasm;
            } else {
                fatal("invalid --vm value: {s} (expected js|wasm)", .{args[i + 1]});
            }
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--audio") and i + 1 < args.len) {
            opts.audio = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--audio-profile") and i + 1 < args.len) {
            if (std.mem.eql(u8, args[i + 1], "clean")) {
                opts.audio_profile = 0;
            } else if (std.mem.eql(u8, args[i + 1], "radio")) {
                opts.audio_profile = 1;
            } else {
                fatal("invalid --audio-profile value: {s} (expected clean|radio)", .{args[i + 1]});
            }
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--strict-format")) {
            opts.strict_format = true;
        } else {
            fatal("unknown flag: {s}", .{args[i]});
        }
    }
    return opts;
}

fn collectSources(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const order_path = try std.fmt.allocPrint(arena, "{s}/ORDER", .{dir_path});
    const order_file = std.Io.Dir.cwd().openFile(io, order_path, .{}) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (order_file) |f| {
        defer f.close(io);
        const order_text = try std.Io.Dir.cwd().readFileAlloc(io, order_path, arena, .limited(1 << 16));
        var lines = std.mem.splitScalar(u8, order_text, '\n');
        while (lines.next()) |l| {
            const t = std.mem.trim(u8, l, " \t\r");
            if (t.len == 0) continue;
            const with_ext = if (std.mem.endsWith(u8, t, ".md")) t else try std.fmt.allocPrint(arena, "{s}.md", .{t});
            try names.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, with_ext }));
        }
    } else {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e|
            fatal("cannot open {s}: {s}", .{ dir_path, @errorName(e) });
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch |e| fatal("cannot iterate {s}: {s}", .{ dir_path, @errorName(e) })) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            try names.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
    }
    return names.toOwnedSlice(arena);
}

fn baseOf(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

const RenderOut = struct {
    page: emitter.Page,
    bytecode: []const u8,
};

// --vm wasm only: walk the compiled bytecode (same slice that reaches the
// emitter) and warn when the state-variable envelope exceeds the wasm VM's
// state table: > 64 distinct names (STATE_ENTRIES) or any name longer than
// NAME_CAP-1 = 31 bytes. Values are heap-stored (no cap) — names only. The
// walk mirrors tests/bytecode.js: str payloads at ops 1,2,4,5,6,7,8,11,12,15,
// 16,27 (8 is str+addr); addr at 9,14,25; no payload elsewhere; strings are
// u16le length + bytes. Unknown opcodes bail out of the walk silently (a
// warning path must never fail the build).
fn wasmEnvelopeWarn(arena: std.mem.Allocator, bytecode: []const u8) void {
    var rest = bytecode;
    if (rest.len >= 2 and rest[0] == 0 and rest[1] == 1) rest = rest[2..]; // --strict-format header
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) {
        const op = rest[i];
        i += 1;
        switch (op) {
            1, 2, 4, 5, 6, 7, 8, 11, 12, 15, 16, 27 => {
                if (i + 2 > rest.len) return;
                const n = @as(usize, rest[i]) | (@as(usize, rest[i + 1]) << 8);
                i += 2;
                if (i + n > rest.len) return;
                switch (op) {
                    11, 12, 15, 16, 27 => {
                        const name = rest[i .. i + n];
                        if (name.len > 31) {
                            std.debug.print("cairn: warning: variable name \"{s}\" is {d} bytes (wasm limit 31) — page will fall back to the JS VM\n", .{ name, name.len });
                        }
                        var dup = false;
                        for (names.items) |prev| if (std.mem.eql(u8, prev, name)) {
                            dup = true;
                            break;
                        };
                        if (!dup) names.append(arena, name) catch return;
                    },
                    else => {},
                }
                i += n;
                if (op == 8) { // ON_EVENT: str + addr
                    if (i + 2 > rest.len) return;
                    i += 2;
                }
            },
            9, 14, 25 => { // JUMP / JMP_IF_FALSE / JMP_IF_TRUE: addr
                if (i + 2 > rest.len) return;
                i += 2;
            },
            3, 10, 13, 17, 18, 19, 20, 21, 22, 23, 24, 26 => {},
            else => return,
        }
    }
    if (names.items.len > 64) {
        std.debug.print("cairn: warning: program uses {d} state variables (wasm limit 64) — page will fall back to the JS VM\n", .{names.items.len});
    }
}

fn renderPage(arena: std.mem.Allocator, io: std.Io, source: []const u8, diag_path: []const u8, base_dir: ?[]const u8, opts: Options) !RenderOut {
    const result = try markdown.renderAll(arena, io, source, base_dir);
    var bytecode: []const u8 = &.{0x0A};
    if (result.dsl) |dsl| {
        var diag: ?parser.Diagnostic = null;
        const program = parser.parse(arena, dsl, &diag) catch |e| {
            if (diag) |d| {
                printDiag(diag_path, source, result.dsl_line_offset + d.line - 1, d.col, d.msg);
            } else {
                std.debug.print("cairn: parse error: {s}\n", .{@errorName(e)});
            }
            return e;
        };
        bytecode = try compiler.compile(arena, program);
    }
    // --strict-format: prefix the versioned stream header (0x00 0x01) before
    // emission so the bytecode bucket and page content stay consistent
    if (opts.strict_format) {
        bytecode = try std.fmt.allocPrint(arena, "\x00\x01{s}", .{bytecode});
    }
    // --vm wasm: the wasm backend's bytecode region is 8 KiB (the glue strips
    // the format prefix before its length check, so mirror that here); the
    // state table (64 x name[31]) is the other hard envelope — warn, don't fail
    if (opts.vm == .wasm) {
        var wasm_bytecode_len = bytecode.len;
        if (wasm_bytecode_len >= 2 and bytecode[0] == 0 and bytecode[1] == 1) wasm_bytecode_len -= 2;
        if (wasm_bytecode_len > 0x2000) {
            std.debug.print("cairn: warning: bytecode is {d} bytes — exceeds the wasm VM's 8 KiB region; page will fall back to the JS VM\n", .{wasm_bytecode_len});
        }
        wasmEnvelopeWarn(arena, bytecode);
    }
    var wasm_b64: ?[]const u8 = null;
    if (opts.vm == .wasm) {
        const wasm = std.Io.Dir.cwd().readFileAlloc(io, "zig-out/bin/vm_wasm.wasm", arena, .limited(1 << 24)) catch
            fatal("run `zig build` first — missing zig-out/bin/vm_wasm.wasm", .{});
        const enc_len = std.base64.standard.Encoder.calcSize(wasm.len);
        const b64 = try arena.alloc(u8, enc_len);
        _ = std.base64.standard.Encoder.encode(b64, wasm);
        wasm_b64 = b64;
    }
    return .{
        .page = try emitter.build(arena, .{
            .content = result.html,
            .bytecode = bytecode,
            .title = result.title orelse "Cairn",
            .debug_encoding = opts.debug_encoding,
            .css = result.css,
            .vm = opts.vm,
            .wasm_b64 = wasm_b64,
        }),
        .bytecode = bytecode,
    };
}

fn buildDecodeHtml(arena: std.mem.Allocator) ![]const u8 {
    const needle = "/*__CAIRN_DECODER__*/";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    var rest: []const u8 = decode_html_tpl;
    var replaced: usize = 0;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        try buf.appendSlice(arena, rest[0..idx]);
        try buf.appendSlice(arena, decoder_js);
        rest = rest[idx + needle.len ..];
        replaced += 1;
    }
    if (replaced == 0) fatal("decode.html template missing /*__CAIRN_DECODER__*/ placeholder", .{});
    try buf.appendSlice(arena, rest);
    return buf.toOwnedSlice(arena);
}

fn buildSource(arena: std.mem.Allocator, io: std.Io, source: []const u8, base_dir: ?[]const u8, input_path: []const u8, opts: Options) !void {
    const out = try renderPage(arena, io, source, input_path, base_dir, opts);
    if (opts.budget) |budget| {
        if (@as(u128, out.page.sizes.total) > @as(u128, budget) * 1024) {
            fatal("budget exceeded: {d} bytes > {d} KB", .{ out.page.sizes.total, budget });
        }
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = opts.output, .data = out.page.html }) catch |e| {
        fatal("cannot write {s}: {s}", .{ opts.output, @errorName(e) });
    };
    emitter.printReport(out.page.sizes, opts.output);
    if (opts.audio) |audio_path| {
        if (std.mem.eql(u8, audio_path, opts.output)) {
            fatal("--audio output must differ from --output (it would overwrite the page)", .{});
        }
        const page_bytes = std.Io.Dir.cwd().readFileAlloc(io, opts.output, arena, .limited(1 << 24)) catch |e|
            fatal("cannot read back {s}: {s}", .{ opts.output, @errorName(e) });
        const wav = audio.encodeProfile(arena, page_bytes, opts.audio_profile) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.BadProfile => fatal("internal error: bad audio profile index {d}", .{opts.audio_profile}),
            else => fatal("audio encode failed: {s}", .{@errorName(e)}),
        };
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = audio_path, .data = wav }) catch |e| {
            fatal("cannot write {s}: {s}", .{ audio_path, @errorName(e) });
        };
        const comp = audio.gzip(arena, page_bytes) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => fatal("audio encode failed: {s}", .{@errorName(e)}),
        };
        const wav_samples: usize = (wav.len - 44) / 2;
        const duration: f64 = @as(f64, @floatFromInt(wav_samples)) / @as(f64, @floatFromInt(audio.SAMPLE_RATE));
        const baud: u32 = audio.SAMPLE_RATE / audio.LINK_PROFILES[opts.audio_profile].samples_per_bit;
        std.debug.print("cairn: wrote {s} ({d} samples, {d} bytes, {d} KB page -> {d} KB gzip, {d:.1}s at {d} bps)\n", .{ audio_path, wav_samples, wav.len, page_bytes.len / 1024, comp.len / 1024, duration, baud });
        const decode_dir = std.fs.path.dirname(audio_path) orelse ".";
        const decode_path = try std.fmt.allocPrint(arena, "{s}/decode.html", .{decode_dir});
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = decode_path, .data = try buildDecodeHtml(arena) }) catch |e| {
            fatal("cannot write {s}: {s}", .{ decode_path, @errorName(e) });
        };
        std.debug.print("cairn: wrote {s}\n", .{decode_path});
    }
}

fn buildOne(arena: std.mem.Allocator, io: std.Io, source: []const u8, path: []const u8, opts: Options) !void {
    const out = try renderPage(arena, io, source, path, baseOf(path), opts);
    if (opts.budget) |budget| {
        if (@as(u128, out.page.sizes.total) > @as(u128, budget) * 1024) {
            std.debug.print("cairn: budget exceeded: {d} bytes > {d} KB\n", .{ out.page.sizes.total, budget });
            return error.BudgetExceeded;
        }
    }

    const base = path[0 .. path.len - 3];
    const bin_path = try std.fmt.allocPrint(arena, "{s}.bin", .{base});
    var bin: std.ArrayList(u8) = .empty;
    defer bin.deinit(arena);
    try emitter.appendBytesLiteral(arena, &bin, out.bytecode);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = bin.items });

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = opts.output, .data = out.page.html });

    const sizes_path = try std.fmt.allocPrint(arena, "{s}.sizes.json", .{base});
    const sizes_json = try std.fmt.allocPrint(arena,
        "{{\"total\":{d},\"shell\":{d},\"content\":{d},\"vm\":{d},\"bytecode\":{d},\"half_life\":{d},\"tier\":\"{s}\"}}",
        .{ out.page.sizes.total, out.page.sizes.shell, out.page.sizes.content, out.page.sizes.vm, out.page.sizes.bytecode, emitter.halfLife(out.page.sizes), emitter.tier(out.page.sizes.total) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sizes_path, .data = sizes_json });
}

fn indexOfAnyPattern(haystack: []const u8, needles: []const []const u8) ?usize {
    var best: ?usize = null;
    for (needles) |needle| {
        const idx = std.mem.indexOf(u8, haystack, needle) orelse continue;
        if (best == null or idx < best.?) best = idx;
    }
    return best;
}

fn verify(io: std.Io, arena: std.mem.Allocator, path: []const u8) !void {
    const html = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24));
    var found: usize = 0;
    const patterns = [_][]const u8{ "https://", "http://", "fetch(", "XMLHttpRequest", "WebSocket", "src=\"http", "href=\"http", "src=\"//", "href=\"//", "@import" };
    // data: URIs (the template's inline favicon, inlined images) are hermetic by
    // construction — strip them before scanning so the SVG xmlns does not trip the audit
    var scrubbed: std.ArrayList(u8) = .empty;
    defer scrubbed.deinit(arena);
    var rest: []const u8 = html;
    while (std.mem.indexOf(u8, rest, "data:")) |idx| {
        try scrubbed.appendSlice(arena, rest[0..idx]);
        // a real data: URI always has its comma before any space (RFC 2397
        // mediatype has no whitespace), so gate the scrub on it: skip only the
        // URI itself and leave any trailing text visible to the audit
        var end = idx + 5;
        var comma = false;
        while (end < rest.len) : (end += 1) {
            const c = rest[end];
            if (c == ',') {
                comma = true;
                continue;
            }
            if (comma) {
                if (c == '"' or c == '>' or c == '\n' or c == '\r') break;
            } else if (c == ' ' or c == '\t' or c == '"' or c == '\'' or c == '>' or c == '\n' or c == '\r') break;
        }
        rest = rest[end..];
    }
    try scrubbed.appendSlice(arena, rest);
    const clean = scrubbed.items;
    var scan: []const u8 = clean;
    var pos: usize = 0;
    while (indexOfAnyPattern(scan, &patterns)) |idx| {
        std.debug.print("  external reference at byte {d}: {s}\n", .{ pos + idx, scan[idx .. @min(scan.len, idx + 40)] });
        found += 1;
        scan = scan[idx + 1 ..];
        pos += idx + 1;
        if (found > 20) break;
    }
    if (found == 0) {
        std.debug.print("OK — 0 external references\n", .{});
    } else {
        std.debug.print("FAIL: {d} external reference(s) found\n", .{found});
        std.process.exit(1);
    }
}

fn demo(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const sample =
        \\# Cairn Demo
        \\
        \\<button id="count">Count</button>
        \\<p id="out">0</p>
        \\
        \\```cairn
        \\let n = 0;
        \\on click "#count" {
        \\    inc n;
        \\    set_text n on "#out";
        \\}
        \\```
        ;
    const md_path = try std.fmt.allocPrint(arena, "{s}/index.md", .{dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = md_path, .data = sample });
    std.debug.print("wrote {s}\n", .{md_path});
    const source = try std.Io.Dir.cwd().readFileAlloc(io, md_path, arena, .limited(max_input));
    const out_path = try std.fmt.allocPrint(arena, "{s}/index.html", .{dir});
    const opts = Options{ .output = out_path };
    try buildOne(arena, io, source, md_path, opts);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usage();

    if (std.mem.eql(u8, args[1], "fixtures")) {
        if (args.len != 3) usage();
        const fixtures_dir = args[2];
        var dir = std.Io.Dir.cwd().openDir(io, fixtures_dir, .{ .iterate = true }) catch |e|
            fatal("cannot open {s}: {s}", .{ fixtures_dir, @errorName(e) });
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch |e| fatal("cannot iterate {s}: {s}", .{ fixtures_dir, @errorName(e) })) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ fixtures_dir, entry.name });
            const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_input)) catch |e| {
                fatal("cannot read {s}: {s}", .{ path, @errorName(e) });
            };
            defer gpa.free(source);
            const opts = Options{ .output = try std.fmt.allocPrint(arena, "{s}.html", .{path[0 .. path.len - 3]}) };
            buildOne(arena, io, source, path, opts) catch |e| {
                fatal("fixture {s}: {s}", .{ entry.name, @errorName(e) });
            };
        }
        std.debug.print("fixtures regenerated in {s}\n", .{fixtures_dir});
        return;
    }

    if (std.mem.eql(u8, args[1], "verify")) {
        if (args.len != 3) usage();
        verify(io, arena, args[2]) catch |e| fatal("verify: {s}", .{@errorName(e)});
        return;
    }

    if (std.mem.eql(u8, args[1], "demo")) {
        if (args.len > 3) usage();
        const dir = if (args.len == 3) args[2] else "./cairn-demo";
        demo(arena, io, dir) catch |e| fatal("demo: {s}", .{@errorName(e)});
        return;
    }

    if (!std.mem.eql(u8, args[1], "build")) usage();
    if (args.len < 3) usage();
    const input_path = args[2];
    const opts = try parseFlags(arena, args, 3);

    var is_dir: bool = false;
    if (std.Io.Dir.cwd().openDir(io, input_path, .{})) |d| {
        d.close(io);
        is_dir = true;
    } else |_| {
        if (!std.mem.endsWith(u8, input_path, ".md")) {
            const order_path = try std.fmt.allocPrint(arena, "{s}/ORDER", .{input_path});
            if (std.Io.Dir.cwd().openFile(io, order_path, .{})) |f| {
                f.close(io);
                is_dir = true;
            } else |_| {}
        }
    }

    const base_dir: ?[]const u8 = if (is_dir) input_path else std.fs.path.dirname(input_path);
    var source: []const u8 = undefined;
    var merged: std.ArrayList(u8) = .empty;
    if (is_dir) {
        const names = try collectSources(arena, io, input_path);
        for (names, 0..) |name, i| {
            const part = std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(max_input)) catch |e|
                fatal("cannot read {s}: {s}", .{ name, @errorName(e) });
            defer gpa.free(part);
            if (i > 0) try merged.appendSlice(arena, "\n\n");
            try merged.appendSlice(arena, part);
        }
        source = merged.items;
    } else {
        source = std.Io.Dir.cwd().readFileAlloc(io, input_path, gpa, .limited(max_input)) catch |e| {
            fatal("cannot read {s}: {s}", .{ input_path, @errorName(e) });
        };
    }
    defer if (!is_dir) gpa.free(source);

    buildSource(arena, io, source, base_dir, input_path, opts) catch |e|
        fatal("build error: {s}", .{@errorName(e)});
}
