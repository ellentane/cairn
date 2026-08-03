const std = @import("std");
const vm_source = @embedFile("vm.js");

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

pub const EmitterError = error{OutOfMemory};

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

pub fn build(allocator: std.mem.Allocator, opts: struct {
    content: []const u8,
    bytecode: []const u8,
    title: []const u8,
}) EmitterError!Page {
    const title_escaped = try escapeTitle(allocator, opts.title);

    var bytes_literal: std.ArrayList(u8) = .empty;
    defer bytes_literal.deinit(allocator);
    try bytes_literal.append(allocator, '[');
    try appendBytesLiteral(allocator, &bytes_literal, opts.bytecode);
    try bytes_literal.append(allocator, ']');
    const bytecode_len = bytes_literal.items.len;

    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(allocator);
    try replaceInto(allocator, &script, vm_source, "__CAIRN_BYTES__", bytes_literal.items);
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
const expectEqualStrings = std.testing.expectEqualStrings;

fn buildWith(content: []const u8, bytecode: []const u8, title: []const u8) !emitter.Page {
    // arena intentionally leaked (page_allocator); deinit would free the page
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return emitter.build(arena.allocator(), .{ .content = content, .bytecode = bytecode, .title = title });
}

test "page contains doctype, title, content, bytecode, provenance, favicon" {
    const page = try buildWith("<h1>Hi</h1>", &[_]u8{ 2, 0x0A }, "My Page");
    try expect(std.mem.startsWith(u8, page.html, "<!DOCTYPE html>"));
    try expect(std.mem.indexOf(u8, page.html, "<title>My Page</title>") != null);
    try expect(std.mem.indexOf(u8, page.html, "<h1>Hi</h1>") != null);
    try expect(std.mem.indexOf(u8, page.html, "cairnBoot([2, 10]);") != null);
    try expect(std.mem.indexOf(u8, page.html, "<!-- built with cairn v0.1 -->") != null);
    try expect(std.mem.indexOf(u8, page.html, "rel=\"icon\" href=\"data:image/svg+xml") != null);
    try expect(std.mem.indexOf(u8, page.html, "src/vm.js") == null);
}

test "size accounting sums to total" {
    const page = try buildWith("<h1>Hi</h1>", &[_]u8{ 2, 0x0A }, "T");
    try expectEqual(page.sizes.total, page.html.len);
    try expectEqual(page.sizes.total, page.sizes.shell + page.sizes.content + page.sizes.vm + page.sizes.bytecode);
    try expectEqual(page.sizes.content, "<h1>Hi</h1>".len);
    try expectEqual(@as(usize, vm_source.len - 15), page.sizes.vm);
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
