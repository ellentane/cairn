const std = @import("std");
const vm_source = @embedFile("vm.js");
const wasm_glue_source = @embedFile("wasm_glue.js");

// --vm wasm embeds the JS VM in definition-only form (its auto-boot tail would
// otherwise register every handler before the wasm path runs). Cut the source
// at the first occurrence of the auto-boot marker; compile-time check keeps
// drift in vm.js from silently double-booting wasm pages.
const auto_boot_marker = "if (typeof document !== \"undefined\") {";
const vm_tail_cut = blk: {
    @setEvalBranchQuota(100000);
    break :blk std.mem.indexOf(u8, vm_source, auto_boot_marker) orelse
        @compileError("vm.js auto-boot tail marker not found; cannot strip it for --vm wasm");
};
const vm_stripped = vm_source[0..vm_tail_cut];

const bootstrap_tpl =
    \\// injected bootstrap — the SINGLE boot point for --vm wasm pages.
    \\// The embedded JS VM source is definition-only: its auto-boot tail
    \\// (the `if (typeof document !== "undefined") { ... cairnBoot(__CAIRN_BYTES__); }`
    \\// block) is stripped by the emitter, so the JS VM never registers handlers
    \\// before the wasm path runs (no double boot).
    \\var __WASM_B64 = "BASE64_PLACEHOLDER"; // filled by the emitter
    \\var __BYTES = TRANSPORT_PLACEHOLDER;   // filled by the emitter: the v0.3 transport
    \\                                       // expression (Uint8Array.from(atob("..."), ...)
    \\                                       // for base64, or the decimal array for
    \\                                       // --debug-encoding)
    \\function __decodeTransport() { return __BYTES; }
    \\function __bootJs() { cairnBoot(__BYTES, document); }
    \\function __bootWasm() {
    \\  var wasmBytes = Uint8Array.from(atob(__WASM_B64), function (c) { return c.charCodeAt(0); });
    \\  cairnBootWasm(wasmBytes, __BYTES, document);
    \\}
    \\try {
    \\  var __hasWasm = false;
    \\  try { __hasWasm = typeof WebAssembly !== "undefined" && typeof WebAssembly.instantiate === "function"; }
    \\  catch (e2) { __hasWasm = false; } // a throwing WebAssembly getter counts as absent
    \\  if (__hasWasm) __bootWasm();
    \\  else __bootJs();
    \\} catch (e) {
    \\  console.error("cairn: wasm backend failed, falling back: " + e.message);
    \\  try { __bootJs(); } catch (e2) { console.error("cairn: JS VM failed: " + e2.message); throw e2; }
    \\}
    ;

pub const Sizes = struct {
    total: usize,
    shell: usize,
    content: usize,
    vm: usize,
    bytecode: usize,
};

pub const Page = struct {
    html: []u8,
    sizes: Sizes,
};

pub const EmitterError = error{ OutOfMemory, MissingWasm };

const template =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ctext y='13' font-size='12'%3E%F0%9F%97%BF%3C/text%3E%3C/svg%3E">
    \\<title>__CAIRN_TITLE__</title>
    \\<style>
    \\body{max-width:42em;margin:2em auto;padding:0 1em;font:16px/1.5 system-ui,sans-serif}
    \\button{cursor:pointer}
    \\</style>
    \\</head>
    \\<body>
    \\<!-- built with cairn v0.1 -->
    \\<main>
    \\__CAIRN_CONTENT__
    \\</main>
    \\<script>
    \\__CAIRN_VM__
    \\</script>
    \\</body>
    \\</html>
    \\
    ;

fn replaceInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8, needle: []const u8, replacement: []const u8) !void {
    var rest: []const u8 = src;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        try out.appendSlice(allocator, rest[0..idx]);
        try out.appendSlice(allocator, replacement);
        rest = rest[idx + needle.len ..];
    }
    try out.appendSlice(allocator, rest);
}

fn escapeTitle(allocator: std.mem.Allocator, title: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (title) |c| switch (c) {
        '&' => try buf.appendSlice(allocator, "&amp;"),
        '<' => try buf.appendSlice(allocator, "&lt;"),
        '>' => try buf.appendSlice(allocator, "&gt;"),
        else => try buf.append(allocator, c),
    };
    return buf.toOwnedSlice(allocator);
}

pub fn appendBytesLiteral(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), bytecode: []const u8) !void {
    for (bytecode, 0..) |b, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        var tmp: [8]u8 = undefined;
        try buf.appendSlice(allocator, std.fmt.bufPrint(&tmp, "{d}", .{b}) catch unreachable);
    }
}

pub const Vm = enum { js, wasm };

pub fn build(allocator: std.mem.Allocator, opts: struct {
    content: []const u8,
    bytecode: []const u8,
    title: []const u8,
    debug_encoding: bool = false,
    css: ?[]const u8 = null,
    vm: Vm = .js,
    wasm_b64: ?[]const u8 = null,
}) EmitterError!Page {
    const title_escaped = try escapeTitle(allocator, opts.title);

    var bytes_expr: std.ArrayList(u8) = .empty;
    defer bytes_expr.deinit(allocator);
    if (opts.debug_encoding) {
        try bytes_expr.append(allocator, '[');
        try appendBytesLiteral(allocator, &bytes_expr, opts.bytecode);
        try bytes_expr.append(allocator, ']');
    } else {
        const encoded_len = std.base64.standard.Encoder.calcSize(opts.bytecode.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, opts.bytecode);
        try bytes_expr.appendSlice(allocator, "Uint8Array.from(atob(\"");
        try bytes_expr.appendSlice(allocator, encoded);
        try bytes_expr.appendSlice(allocator, "\"), function(c){return c.charCodeAt(0);})");
    }
    const bytecode_len = opts.bytecode.len;
    // bytecode bucket = true bytecode length (encoding-independent metric);
    // the transport wrapper (base64 expression) counts toward the vm bucket

    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(allocator);
    switch (opts.vm) {
        .js => try replaceInto(allocator, &script, vm_source, "__CAIRN_BYTES__", bytes_expr.items),
        .wasm => {
            const wasm_b64 = opts.wasm_b64 orelse return error.MissingWasm;
            try script.appendSlice(allocator, vm_stripped);
            try script.appendSlice(allocator, "\n\n");
            try script.appendSlice(allocator, wasm_glue_source);
            try script.appendSlice(allocator, "\n\n");
            var boot: std.ArrayList(u8) = .empty;
            defer boot.deinit(allocator);
            try replaceInto(allocator, &boot, bootstrap_tpl, "BASE64_PLACEHOLDER", wasm_b64);
            var boot2: std.ArrayList(u8) = .empty;
            defer boot2.deinit(allocator);
            try replaceInto(allocator, &boot2, boot.items, "TRANSPORT_PLACEHOLDER", bytes_expr.items);
            try script.appendSlice(allocator, boot2.items);
        },
    }
    const vm_len = script.items.len - bytecode_len;

    var staged: std.ArrayList(u8) = .empty;
    defer staged.deinit(allocator);
    try replaceInto(allocator, &staged, template, "__CAIRN_VM__", script.items);

    var staged2: std.ArrayList(u8) = .empty;
    defer staged2.deinit(allocator);
    try replaceInto(allocator, &staged2, staged.items, "__CAIRN_CONTENT__", opts.content);

    var page: std.ArrayList(u8) = .empty;
    defer page.deinit(allocator);
    try replaceInto(allocator, &page, staged2.items, "__CAIRN_TITLE__", title_escaped);

    if (opts.css) |css| {
        const style_close = std.mem.indexOf(u8, page.items, "</style>").?;
        try page.insertSlice(allocator, style_close, css);
    }

    const total = page.items.len;
    const content_len = opts.content.len;
    const shell_len = total - content_len - vm_len - bytecode_len;

    return .{
        .html = try page.toOwnedSlice(allocator),
        .sizes = .{
            .total = total,
            .shell = shell_len,
            .content = content_len,
            .vm = vm_len,
            .bytecode = bytecode_len,
        },
    };
}

pub fn halfLife(sizes: Sizes) i64 {
    if (sizes.total == 0) return 100;
    const score = 100.0 * (1.0 - @as(f64, @floatFromInt(sizes.bytecode)) / @as(f64, @floatFromInt(sizes.total)));
    return std.math.clamp(@as(i64, @intFromFloat(@round(score))), 0, 100);
}

pub fn tier(total: usize) []const u8 {
    return if (total < 4 * 1024)
        "Tombstone"
    else if (total < 16 * 1024)
        "Monolith"
    else if (total < 64 * 1024)
        "Obelisk"
    else
        "Megalith";
}

pub fn printReport(sizes: Sizes, output_path: []const u8) void {
    std.debug.print("Cairn Build Complete.\n", .{});
    std.debug.print("Output: {s}\n", .{output_path});
    std.debug.print("Total Size: {d:.2} KB\n", .{kb(sizes.total)});
    std.debug.print("  - HTML/CSS: {d:.2} KB\n", .{kb(sizes.shell)});
    std.debug.print("  - VM Runtime: {d:.2} KB\n", .{kb(sizes.vm)});
    std.debug.print("  - Executable Bytecode: {d:.2} KB\n", .{kb(sizes.bytecode)});
    std.debug.print("  - Content Payload: {d:.2} KB\n", .{kb(sizes.content)});
    std.debug.print("\nHalf-Life Score: {d}% (Executable economy) — Tier: {s}\n", .{ halfLife(sizes), tier(sizes.total) });
}

fn kb(n: usize) f64 {
    return @as(f64, @floatFromInt(n)) / 1024.0;
}

const emitter = @import("emitter.zig");
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

fn buildWith(content: []const u8, bytecode: []const u8, title: []const u8) !emitter.Page {
    return buildWithOpts(content, bytecode, title, false, null);
}

fn buildWithOpts(content: []const u8, bytecode: []const u8, title: []const u8, debug_encoding: bool, css: ?[]const u8) !emitter.Page {
    // arena intentionally leaked (page_allocator); deinit would free the page
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return emitter.build(arena.allocator(), .{ .content = content, .bytecode = bytecode, .title = title, .debug_encoding = debug_encoding, .css = css });
}

fn buildWasm(content: []const u8, bytecode: []const u8, title: []const u8, debug_encoding: bool) !emitter.Page {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return emitter.build(arena.allocator(), .{ .content = content, .bytecode = bytecode, .title = title, .debug_encoding = debug_encoding, .vm = .wasm, .wasm_b64 = "AAECAw==" });
}

test "page contains doctype, title, content, bytecode, provenance, favicon" {
    const page = try buildWith("<h1>Hi</h1>", &[_]u8{ 2, 0x0A }, "My Page");
    try expect(std.mem.startsWith(u8, page.html, "<!DOCTYPE html>"));
    try expect(std.mem.indexOf(u8, page.html, "<title>My Page</title>") != null);
    try expect(std.mem.indexOf(u8, page.html, "<h1>Hi</h1>") != null);
    try expect(std.mem.indexOf(u8, page.html, "cairnBoot(Uint8Array.from(atob(\"") != null);
    try expect(std.mem.indexOf(u8, page.html, "<!-- built with cairn v0.1 -->") != null);
    try expect(std.mem.indexOf(u8, page.html, "rel=\"icon\" href=\"data:image/svg+xml") != null);
    try expect(std.mem.indexOf(u8, page.html, "src/vm.js") == null);
}

test "size accounting sums to total" {
    const page = try buildWith("<h1>Hi</h1>", &[_]u8{ 2, 0x0A }, "T");
    try expectEqual(page.sizes.total, page.html.len);
    try expectEqual(page.sizes.total, page.sizes.shell + page.sizes.content + page.sizes.vm + page.sizes.bytecode);
    try expectEqual(page.sizes.content, "<h1>Hi</h1>".len);
    try expectEqual(@as(usize, 2), page.sizes.bytecode);
}

test "half-life math" {
    try expectEqual(@as(i64, 89), emitter.halfLife(.{ .total = 3910, .shell = 750, .content = 850, .vm = 1880, .bytecode = 430 }));
    try expectEqual(@as(i64, 100), emitter.halfLife(.{ .total = 100, .shell = 90, .content = 0, .vm = 10, .bytecode = 0 }));
    try expectEqual(@as(i64, 0), emitter.halfLife(.{ .total = 100, .shell = 0, .content = 0, .vm = 0, .bytecode = 100 }));
}

test "title is escaped" {
    const page = try buildWith("", &[_]u8{0x0A}, "A < B");
    try expect(std.mem.indexOf(u8, page.html, "<title>A &lt; B</title>") != null);
}

test "script tag in content does not corrupt accounting" {
    const page = try buildWith("<script>alert(1)</script>", &[_]u8{0x0A}, "T");
    try expectEqual(page.sizes.total, page.html.len);
    try expectEqual(page.sizes.total, page.sizes.shell + page.sizes.content + page.sizes.vm + page.sizes.bytecode);
    try expectEqual(page.sizes.content, "<script>alert(1)</script>".len);
    const page2 = try buildWith("<script></script>", &[_]u8{0x0A}, "T");
    try expectEqual(page2.sizes.total, page2.html.len);
    try expectEqual(page2.sizes.vm, page.sizes.vm);
}

test "title containing placeholder literal is not clobbered" {
    const page = try buildWith("<p>x</p>", &[_]u8{0x0A}, "__CAIRN_CONTENT__");
    try expect(std.mem.indexOf(u8, page.html, "<title>__CAIRN_CONTENT__</title>") != null);
    try expect(std.mem.indexOf(u8, page.html, "<p>x</p>") != null);
}

test "tier naming" {
    try expectEqualStrings("Tombstone", emitter.tier(3900));
    try expectEqualStrings("Tombstone", emitter.tier(4095));
    try expectEqualStrings("Monolith", emitter.tier(4096));
    try expectEqualStrings("Monolith", emitter.tier(16383));
    try expectEqualStrings("Obelisk", emitter.tier(16384));
    try expectEqualStrings("Obelisk", emitter.tier(65535));
    try expectEqualStrings("Megalith", emitter.tier(65536));
}

test "base64 transport by default" {
    const page = try buildWith("<h1>Hi</h1>", &[_]u8{ 0x02, 0x0A }, "T");
    const needle = "cairnBoot(Uint8Array.from(atob(\"";
    try expect(std.mem.indexOf(u8, page.html, needle) != null);
    // decode the base64 literal and compare with the bytecode
    const lit_start = std.mem.indexOf(u8, page.html, needle).? + needle.len;
    const lit_end = std.mem.indexOfScalarPos(u8, page.html, lit_start, '"').?;
    const b64 = page.html[lit_start..lit_end];
    const dec = std.base64.standard.Decoder;
    const size = try dec.calcSizeForSlice(b64);
    const out = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(out);
    try dec.decode(out, b64);
    try expectEqualSlices(u8, &[_]u8{ 0x02, 0x0A }, out);
    try expect(std.mem.indexOf(u8, page.html, "charCodeAt(0);}));") != null);
}

test "decimal transport via options" {
    const page = try buildWithOpts("", &[_]u8{ 0x0A }, "T", true, null); // debug_encoding
    try expect(std.mem.indexOf(u8, page.html, "cairnBoot([10]);") != null);
}

test "wasm vm mode assembles glue, bootstrap, and no auto-boot tail" {
    const page = try buildWasm("<h1>Hi</h1>", &[_]u8{ 0x02, 0x0A }, "T", false);
    try expect(std.mem.indexOf(u8, page.html, "cairnBootWasm") != null);
    try expect(std.mem.indexOf(u8, page.html, "var __WASM_B64 = \"AAECAw==\";") != null);
    try expect(std.mem.indexOf(u8, page.html, "cairnBootWasm(wasmBytes, __BYTES, document);") != null);
    // the JS VM is definition-only: auto-boot tail stripped, no double boot
    // (the bootstrap *comment* quotes the tail; assert on the executable form)
    try expect(std.mem.indexOf(u8, page.html, "var go = function() { cairnBoot(") == null);
    // the strip cut after cairnBoot's closing brace: its return statement is
    // present and the glue header immediately follows the stripped source
    try expect(std.mem.indexOf(u8, page.html, "isNum: isNum };") != null);
    try expect(std.mem.indexOf(u8, page.html, "// Cairn WASM VM glue").? > std.mem.indexOf(u8, page.html, "isNum: isNum };").?);
    try expectEqual(page.sizes.total, page.html.len);
    try expectEqual(page.sizes.total, page.sizes.shell + page.sizes.content + page.sizes.vm + page.sizes.bytecode);
}

test "wasm vm mode size accounting mirrors js mode formula" {
    const page = try buildWasm("<p>x</p>", &[_]u8{ 0x02, 0x0A }, "T", false);
    const page_js = try buildWith("<p>x</p>", &[_]u8{ 0x02, 0x0A }, "T");
    try expectEqual(page_js.sizes.bytecode, page.sizes.bytecode);
    try expect(page.sizes.vm > page_js.sizes.vm); // glue + wasm literal + bootstrap
}

test "wasm vm mode respects debug_encoding transport" {
    const page = try buildWasm("", &[_]u8{0x0A}, "T", true);
    try expect(std.mem.indexOf(u8, page.html, "var __BYTES = [10];") != null);
    // no base64 transport when debug_encoding
    try expect(std.mem.indexOf(u8, page.html, "__BYTES = Uint8Array.from(atob(") == null);
}

test "wasm vm mode: strict-format prefix + debug-encoding transport is slice-safe" {
    // 0x00 0x01 prefix + decimal Array transport: the glue must strip the
    // prefix with slice (Array has no subarray — a subarray call would throw
    // and silently fall back to the JS VM)
    const page = try buildWasm("", &[_]u8{ 0x00, 0x01, 0x0A }, "T", true);
    try expect(std.mem.indexOf(u8, page.html, "var __BYTES = [0, 1, 10];") != null);
    try expect(std.mem.indexOf(u8, page.html, "bytecode = bytecode.slice(2);") != null);
    try expect(std.mem.indexOf(u8, page.html, "bytecode = bytecode.subarray(2);") == null);
}

test "wasm vm mode requires the wasm blob" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    try expectError(error.MissingWasm, emitter.build(arena.allocator(), .{ .content = "", .bytecode = &[_]u8{0x0A}, .title = "T", .vm = .wasm }));
}

test "css injection" {
    const page = try buildWithOpts("", &[_]u8{0x0A}, "T", false, "h1 { color: red; }");
    try expect(std.mem.indexOf(u8, page.html, "h1 { color: red; }") != null);
    // css lands inside <style>
    const style_open = std.mem.indexOf(u8, page.html, "<style>").?;
    const style_close = std.mem.indexOf(u8, page.html, "</style>").?;
    try expect(style_open < std.mem.indexOf(u8, page.html, "h1 { color: red; }").? and
        std.mem.indexOf(u8, page.html, "h1 { color: red; }").? < style_close);
}

test "half-life is encoding-independent" {
    const page = try buildWith("<h1>Hi</h1>", &[_]u8{ 0x02, 0x0A }, "T");
    const page_debug = try buildWithOpts("<h1>Hi</h1>", &[_]u8{ 0x02, 0x0A }, "T", true, null);
    try expectEqual(emitter.halfLife(page.sizes), emitter.halfLife(page_debug.sizes));
}

test "css injection preserves size accounting" {
    const page = try buildWithOpts("", &[_]u8{0x0A}, "T", false, "h1 { color: red; }");
    try expectEqual(page.sizes.total, page.html.len);
    try expectEqual(page.sizes.total, page.sizes.shell + page.sizes.content + page.sizes.vm + page.sizes.bytecode);
}
