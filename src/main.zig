const std = @import("std");
const markdown = @import("markdown.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const emitter = @import("emitter.zig");

const max_input: usize = 1 << 20;

const Options = struct {
    output: []const u8 = "index.html",
    budget: ?usize = null,
    debug_encoding: bool = false,
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cairn: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print("usage: cairn build <input.md|dir> [--output <file>] [--budget <kb>] [--debug-encoding] | cairn verify <file> | cairn demo [dir] | cairn fixtures <dir>\n", .{});
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
    return .{
        .page = try emitter.build(arena, .{
            .content = result.html,
            .bytecode = bytecode,
            .title = result.title orelse "Cairn",
            .debug_encoding = opts.debug_encoding,
            .css = result.css,
        }),
        .bytecode = bytecode,
    };
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
