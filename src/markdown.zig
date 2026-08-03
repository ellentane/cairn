const std = @import("std");
const markdown = @import("markdown.zig"); // self-import for tests

pub const MarkdownError = error{ MultipleCairnBlocks, MultipleStyleBlocks, OutOfMemory };

pub const RenderResult = struct {
    html: []u8,
    dsl: ?[]const u8,
    /// 1-based line number of the first line inside the cairn fence
    /// (fence opener line + 1) in the source file; 0 when no cairn block.
    dsl_line_offset: u32,
    /// First H1 in document order (raw HTML passthrough included), or null.
    title: ?[]const u8,
    css: ?[]const u8,
};

const MarkdownParser = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: ?[]const u8,
    html: std.ArrayList(u8),
    para: std.ArrayList([]const u8),
    list: std.ArrayList([]const u8),
    ol_items: std.ArrayList([]const u8),
    blockquote_lines: std.ArrayList([]const u8),
    table_lines: std.ArrayList([]const u8),
    cells_buf: [32][]const u8 = undefined,
    // reserved for future inline-in-pre behavior
    in_pre: bool,
    dsl: ?[]const u8,
    dsl_line_offset: u32,
    title: ?[]const u8,
    css: ?[]const u8,

    fn flushPara(self: *MarkdownParser) !void {
        if (self.para.items.len == 0) return;
        // single-line raw HTML element (starts and ends with angle brackets)
        // passes through untouched, without a paragraph wrapper or escaping
        if (self.para.items.len == 1) {
            const line = self.para.items[0];
            const t = std.mem.trim(u8, line, " \t");
            if (t.len > 0 and t[0] == '<' and t[t.len - 1] == '>') {
                try self.html.appendSlice(self.allocator, t);
                try self.html.append(self.allocator, '\n');
                self.para.clearRetainingCapacity();
                return;
            }
        }
        try self.html.appendSlice(self.allocator, "<p>");
        for (self.para.items, 0..) |line, i| {
            if (i > 0) try self.html.append(self.allocator, '\n');
            try renderInline(self, &self.html, line);
        }
        try self.html.appendSlice(self.allocator, "</p>\n");
        self.para.clearRetainingCapacity();
    }

    fn flushList(self: *MarkdownParser) !void {
        if (self.list.items.len == 0) return;
        try self.html.appendSlice(self.allocator, "<ul>\n");
        for (self.list.items) |item| {
            try self.html.appendSlice(self.allocator, "<li>");
            try renderInline(self, &self.html, item);
            try self.html.appendSlice(self.allocator, "</li>\n");
        }
        try self.html.appendSlice(self.allocator, "</ul>\n");
        self.list.clearRetainingCapacity();
    }

    fn flushOl(self: *MarkdownParser) !void {
        if (self.ol_items.items.len == 0) return;
        try self.html.appendSlice(self.allocator, "<ol>\n");
        for (self.ol_items.items) |item| {
            try self.html.appendSlice(self.allocator, "<li>");
            try renderInline(self, &self.html, item);
            try self.html.appendSlice(self.allocator, "</li>\n");
        }
        try self.html.appendSlice(self.allocator, "</ol>\n");
        self.ol_items.clearRetainingCapacity();
    }

    fn flushBlockquote(self: *MarkdownParser) !void {
        if (self.blockquote_lines.items.len == 0) return;
        try self.html.appendSlice(self.allocator, "<blockquote>\n<p>");
        for (self.blockquote_lines.items, 0..) |l, i| {
            if (i > 0) try self.html.append(self.allocator, '\n');
            try renderInline(self, &self.html, l);
        }
        try self.html.appendSlice(self.allocator, "</p>\n</blockquote>\n");
        self.blockquote_lines.clearRetainingCapacity();
    }

    fn isTableSeparator(line: []const u8) bool {
        for (line) |c| switch (c) {
            '|', '-', ':', ' ', '\t' => {},
            else => return false,
        };
        return std.mem.indexOfScalar(u8, line, '-') != null;
    }

    fn splitRow(self: *MarkdownParser, line: []const u8) []const []const u8 {
        self.cells_buf = undefined;
        var cells: [32][]const u8 = undefined;
        var n: usize = 0;
        var truncated = false;
        var it = std.mem.splitScalar(u8, line, '|');
        while (it.next()) |seg| {
            const t = std.mem.trim(u8, seg, " \t");
            if (n == 0 and t.len == 0) continue; // drop leading empty
            if (n < 32) {
                cells[n] = t;
                n += 1;
            } else {
                truncated = true;
            }
        }
        if (truncated) std.debug.print("cairn: warning: table row exceeds 32 columns; truncating\n", .{});
        while (n > 0 and cells[n - 1].len == 0) n -= 1; // drop trailing empty
        // cells_buf is a parser field because the returned slice must outlive
        // this frame; a slice of the function-local array would dangle
        self.cells_buf = cells;
        return self.cells_buf[0..n];
    }

    fn flushTable(self: *MarkdownParser) !void {
        const lines = self.table_lines.items;
        // validate: header + separator + at least one body row; otherwise the
        // buffered lines are re-emitted as paragraphs (no silent content loss)
        if (lines.len < 3 or !MarkdownParser.isTableSeparator(lines[1])) {
            for (lines) |l| {
                try self.html.appendSlice(self.allocator, "<p>");
                try renderInline(self, &self.html, l);
                try self.html.appendSlice(self.allocator, "</p>\n");
            }
            self.table_lines.clearRetainingCapacity();
            return;
        }
        const header = self.splitRow(lines[0]);
        try self.html.appendSlice(self.allocator, "<table>\n<thead>\n<tr>");
        for (header) |cell| {
            try self.html.appendSlice(self.allocator, "<th>");
            try renderInline(self, &self.html, std.mem.trim(u8, cell, " \t"));
            try self.html.appendSlice(self.allocator, "</th>");
        }
        try self.html.appendSlice(self.allocator, "</tr>\n</thead>\n<tbody>\n");
        for (lines[2..]) |row| {
            try self.html.appendSlice(self.allocator, "<tr>");
            for (self.splitRow(row)) |cell| {
                try self.html.appendSlice(self.allocator, "<td>");
                try renderInline(self, &self.html, std.mem.trim(u8, cell, " \t"));
                try self.html.appendSlice(self.allocator, "</td>");
            }
            try self.html.appendSlice(self.allocator, "</tr>\n");
        }
        try self.html.appendSlice(self.allocator, "</tbody>\n</table>\n");
        self.table_lines.clearRetainingCapacity();
    }

    fn flushAll(self: *MarkdownParser) !void {
        try self.flushPara();
        try self.flushList();
        try self.flushOl();
        try self.flushBlockquote();
        try self.flushTable();
    }

    fn setTitle(self: *MarkdownParser, text: []const u8) !void {
        if (self.title == null) self.title = try self.allocator.dupe(u8, std.mem.trim(u8, text, " \t"));
    }

    fn handleFence(self: *MarkdownParser, opener: []const u8, line_no: u32, lines: *std.mem.SplitIterator(u8, .scalar)) MarkdownError!void {
        const info = std.mem.trim(u8, opener[3..], " \t");
        if (std.mem.eql(u8, info, "cairn")) {
            if (self.dsl != null) return error.MultipleCairnBlocks;
            self.dsl_line_offset = line_no + 1; // first DSL line inside the fence
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            var closed = false;
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "```")) {
                    closed = true;
                    break;
                }
                try buf.appendSlice(self.allocator, line);
                try buf.append(self.allocator, '\n');
            }
            if (closed and buf.items.len > 0) buf.items.len -= 1;
            self.dsl = try self.allocator.dupe(u8, buf.items);
            return;
        }
        if (std.mem.eql(u8, info, "cairn-css")) {
            if (self.css != null) return error.MultipleStyleBlocks;
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "```")) {
                    if (buf.items.len > 0) buf.items.len -= 1; // drop trailing \n
                    self.css = try self.allocator.dupe(u8, buf.items);
                    return;
                }
                try buf.appendSlice(self.allocator, line);
                try buf.append(self.allocator, '\n');
            }
            std.debug.print("cairn: warning: unterminated cairn-css fence; css ignored\n", .{});
            return;
        }
        // language-tagged fence (any info string)
        self.in_pre = true;
        if (info.len > 0) {
            try self.html.appendSlice(self.allocator, "<pre><code class=\"language-");
            try appendEscaped(self.allocator, &self.html, info);
            try self.html.appendSlice(self.allocator, "\">");
        } else {
            try self.html.appendSlice(self.allocator, "<pre><code>");
        }
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "```")) {
                self.in_pre = false;
                try self.html.appendSlice(self.allocator, "</code></pre>\n");
                return;
            }
            try appendEscaped(self.allocator, &self.html, line);
            try self.html.append(self.allocator, '\n');
        }
        self.in_pre = false;
        try self.html.appendSlice(self.allocator, "</code></pre>\n"); // unterminated fence closes at EOF
    }
};

fn isBlank(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn isTableRow(line: []const u8) bool {
    return line.len > 0 and line[0] == '|';
}

fn isOlItem(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    return i > 0 and i < line.len and (line[i] == '.' or line[i] == ')') and i + 1 < line.len and line[i + 1] == ' ';
}

fn appendNum(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), n: usize) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

fn appendEscaped(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try buf.appendSlice(allocator, "&amp;"),
        '<' => try buf.appendSlice(allocator, "&lt;"),
        '>' => try buf.appendSlice(allocator, "&gt;"),
        '"' => try buf.appendSlice(allocator, "&quot;"),
        else => try buf.append(allocator, c),
    };
}

fn renderInline(p: *MarkdownParser, buf: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '<') {
            if (std.mem.indexOfScalarPos(u8, text, i, '>')) |end| {
                try buf.appendSlice(p.allocator, text[i .. end + 1]);
                i = end + 1;
                continue;
            }
            try buf.appendSlice(p.allocator, "&lt;");
            i += 1;
            continue;
        }
        if (c == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 2, ']')) |close| {
                if (close + 1 < text.len and text[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |paren| {
                        const alt = text[i + 2 .. close];
                        const src = text[close + 2 .. paren];
                        try appendImage(p, buf, alt, src);
                        i = paren + 1;
                        continue;
                    }
                }
            }
        }
        if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            const rest = text[i + 2 ..];
            if (std.mem.indexOf(u8, rest, "**")) |end| {
                try buf.appendSlice(p.allocator, "<strong>");
                try renderInline(p, buf, rest[0..end]);
                try buf.appendSlice(p.allocator, "</strong>");
                i += 2 + end + 2;
                continue;
            }
        }
        if (c == '*') {
            const rest = text[i + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '*')) |end| {
                try buf.appendSlice(p.allocator, "<em>");
                try renderInline(p, buf, rest[0..end]);
                try buf.appendSlice(p.allocator, "</em>");
                i += 1 + end + 1;
                continue;
            }
        }
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close| {
                if (close + 1 < text.len and text[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |paren| {
                        const href = text[close + 2 .. paren];
                        try buf.appendSlice(p.allocator, "<a href=\"");
                        try appendEscaped(p.allocator, buf, href);
                        try buf.appendSlice(p.allocator, "\">");
                        try renderInline(p, buf, text[i + 1 .. close]);
                        try buf.appendSlice(p.allocator, "</a>");
                        i = paren + 1;
                        continue;
                    }
                }
            }
        }
        switch (c) {
            '&' => try buf.appendSlice(p.allocator, "&amp;"),
            '<' => try buf.appendSlice(p.allocator, "&lt;"),
            '>' => try buf.appendSlice(p.allocator, "&gt;"),
            else => try buf.append(p.allocator, c),
        }
        i += 1;
    }
}

fn appendImage(p: *MarkdownParser, buf: *std.ArrayList(u8), alt: []const u8, src: []const u8) !void {
    if (std.mem.startsWith(u8, src, "http://") or std.mem.startsWith(u8, src, "https://")) {
        std.debug.print("cairn: warning: remote image ignored (hermetic): {s}\n", .{src});
        try buf.appendSlice(p.allocator, "<img alt=\"");
        try appendEscaped(p.allocator, buf, alt);
        try buf.appendSlice(p.allocator, "\">");
        return;
    }
    if (p.base_dir) |dir| {
        const full = std.fmt.allocPrint(p.allocator, "{s}/{s}", .{ dir, src }) catch return error.OutOfMemory;
        const bytes = std.Io.Dir.cwd().readFileAlloc(p.io, full, p.allocator, .limited(1 << 20)) catch {
            std.debug.print("cairn: warning: image not found: {s}\n", .{src});
            try buf.appendSlice(p.allocator, "<img alt=\"");
            try appendEscaped(p.allocator, buf, alt);
            try buf.appendSlice(p.allocator, "\">");
            return;
        };
        if (bytes.len > 100 * 1024) {
            std.debug.print("cairn: warning: inlined image exceeds 100 KB: {s} ({d} bytes)\n", .{ src, bytes.len });
        }
        const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
        const encoded = p.allocator.alloc(u8, encoded_len) catch return error.OutOfMemory;
        _ = std.base64.standard.Encoder.encode(encoded, bytes);
        try buf.appendSlice(p.allocator, "<img alt=\"");
        try appendEscaped(p.allocator, buf, alt);
        try buf.appendSlice(p.allocator, "\" src=\"data:image/png;base64,");
        try buf.appendSlice(p.allocator, encoded);
        try buf.appendSlice(p.allocator, "\">");
        return;
    }
    std.debug.print("cairn: warning: image skipped (no base dir): {s}\n", .{src});
    try buf.appendSlice(p.allocator, "<img alt=\"");
    try appendEscaped(p.allocator, buf, alt);
    try buf.appendSlice(p.allocator, "\">");
}

pub fn renderAll(allocator: std.mem.Allocator, io: std.Io, src: []const u8, base_dir: ?[]const u8) MarkdownError!RenderResult {
    var p = MarkdownParser{
        .allocator = allocator,
        .io = io,
        .base_dir = base_dir,
        .html = .empty,
        .para = .empty,
        .list = .empty,
        .ol_items = .empty,
        .blockquote_lines = .empty,
        .table_lines = .empty,
        .in_pre = false,
        .dsl = null,
        .dsl_line_offset = 0,
        .title = null,
        .css = null,
    };
    errdefer p.html.deinit(allocator);
    defer p.para.deinit(allocator);
    defer p.list.deinit(allocator);
    defer p.ol_items.deinit(allocator);
    defer p.blockquote_lines.deinit(allocator);
    defer p.table_lines.deinit(allocator);

    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.startsWith(u8, line, "```")) {
            try p.flushAll();
            try p.handleFence(line, line_no, &lines);
            continue;
        }
        if (line.len > 0 and line[0] == '#' and line.len > 1 and (line[1] == ' ' or line[1] == '#')) {
            try p.flushAll();
            var level: usize = 1;
            while (level < line.len and level < 6 and line[level] == '#') level += 1;
            const text = line[level..];
            if (level == 1) try p.setTitle(text);
            try p.html.appendSlice(allocator, "<h");
            try appendNum(allocator, &p.html, level);
            try p.html.appendSlice(allocator, ">");
            try renderInline(&p, &p.html, std.mem.trim(u8, text, " \t"));
            try p.html.appendSlice(allocator, "</h");
            try appendNum(allocator, &p.html, level);
            try p.html.appendSlice(allocator, ">\n");
            continue;
        }
        // raw HTML H1: <h1 ...>text</h1> — title source (spec §8)
        if (std.mem.startsWith(u8, line, "<h1") and std.mem.indexOf(u8, line, "</h1>") != null) {
            if (p.title == null) {
                const open_end = std.mem.indexOfScalar(u8, line, '>').?;
                const close_start = std.mem.indexOf(u8, line, "</h1>").?;
                try p.setTitle(line[open_end + 1 .. close_start]);
            }
        }
        if (std.mem.startsWith(u8, line, "> ") or (line.len == 1 and line[0] == '>')) {
            try p.flushPara();
            try p.flushList();
            try p.flushOl();
            try p.flushTable();
            const content = if (line.len > 1) line[2..] else "";
            try p.blockquote_lines.append(allocator, content);
            continue;
        }
        if (isTableRow(line)) {
            try p.flushPara();
            try p.flushList();
            try p.flushOl();
            try p.flushBlockquote();
            try p.table_lines.append(allocator, line);
            continue;
        }
        if (isOlItem(line)) {
            try p.flushPara();
            try p.flushList();
            try p.flushBlockquote();
            try p.flushTable();
            var idx: usize = 0;
            while (idx < line.len and std.ascii.isDigit(line[idx])) idx += 1;
            try p.ol_items.append(allocator, line[idx + 2 ..]);
            continue;
        }
        if (line.len > 1 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
            try p.flushPara();
            try p.flushOl();
            try p.flushBlockquote();
            try p.flushTable();
            try p.list.append(allocator, line[2..]);
            continue;
        }
        if (isBlank(line)) {
            try p.flushAll();
            continue;
        }
        try p.flushAll();
        try p.para.append(allocator, line);
    }
    try p.flushAll();

    return .{
        .html = try p.html.toOwnedSlice(allocator),
        .dsl = p.dsl,
        .dsl_line_offset = p.dsl_line_offset,
        .title = p.title,
        .css = p.css,
    };
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const expect = std.testing.expect;

fn renderWith(src: []const u8) !markdown.RenderResult {
    // leaked-arena pattern (page_allocator, no deinit)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return markdown.renderAll(arena.allocator(), std.Io.Threaded.global_single_threaded.io(), src, null);
}

test "heading, paragraph, strong, em, link" {
    const r = try renderWith("# Hello\n\n**bold** and *em* and [t](https://x)\n");
    try expectEqualStrings("<h1>Hello</h1>\n<p><strong>bold</strong> and <em>em</em> and <a href=\"https://x\">t</a></p>\n", r.html);
    try expectEqualStrings("Hello", r.title.?);
}

test "unordered list" {
    const r = try renderWith("- one\n- two\n");
    try expectEqualStrings("<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n", r.html);
}

test "raw HTML passes through, text is escaped" {
    const r = try renderWith("<button id=\"b\">A & B</button>\n\ntext with <tag-like\n");
    try expectEqualStrings("<button id=\"b\">A & B</button>\n<p>text with &lt;tag-like</p>\n", r.html);
}

test "code fence renders escaped pre" {
    const r = try renderWith("```js\nif (a < b) {}\n```\n");
    try expectEqualStrings("<pre><code class=\"language-js\">if (a &lt; b) {}\n</code></pre>\n", r.html);
}

test "cairn fence is extracted, not rendered" {
    const r = try renderWith("# T\n\n```cairn\non click \"#b\" { set_text \"x\" on \"#o\"; }\n```\n\nafter\n");
    try expectEqualStrings("<h1>T</h1>\n<p>after</p>\n", r.html);
    try expectEqualStrings("on click \"#b\" { set_text \"x\" on \"#o\"; }", r.dsl.?);
    try expectEqual(@as(u32, 4), r.dsl_line_offset);
}

test "second cairn block is an error" {
    try expectError(error.MultipleCairnBlocks, renderWith("```cairn\non click \"#a\" { }\n```\n```cairn\non click \"#b\" { }\n```\n"));
}

test "title falls back to raw h1 html" {
    const r = try renderWith("<h1 class=\"x\">Raw</h1>\n");
    try expectEqualStrings("Raw", r.title.?);
}

test "title keeps raw inline markup (documented limitation)" {
    const r = try renderWith("# **Bold** Title\n");
    try expectEqualStrings("**Bold** Title", r.title.?);
}

test "h2 through h6 headings" {
    const r = try renderWith("## sub\n\n### mid\n\n###### six\n");
    try expectEqualStrings("<h2>sub</h2>\n<h3>mid</h3>\n<h6>six</h6>\n", r.html);
    try expectEqual(@as(?[]const u8, null), r.title); // h1 only sets title
}

test "href quotes are escaped" {
    const r = try renderWith("[x](a\"b)\n");
    try expect(std.mem.indexOf(u8, r.html, "a&quot;b") != null);
    try expect(std.mem.indexOf(u8, r.html, "a\"b") == null);
}

test "unterminated fence closes at EOF" {
    const r = try renderWith("```js\nif (a) {}");
    try expectEqualStrings("<pre><code class=\"language-js\">if (a) {}\n</code></pre>\n", r.html);
}

test "em/strong nesting is a documented limitation" {
    const r = try renderWith("*a **b** c*\n");
    // pin current behavior: inner ** does not nest inside <em> (v0.1 scope)
    try expectEqualStrings("<p><em>a </em><em>b</em><em> c</em></p>\n", r.html);
}

test "plain ampersand is escaped" {
    const r = try renderWith("a & b\n");
    try expectEqualStrings("<p>a &amp; b</p>\n", r.html);
}

test "empty document" {
    const r = try renderWith("");
    try expectEqualStrings("", r.html);
    try expectEqual(@as(?[]const u8, null), r.title);
    try expectEqual(@as(?[]const u8, null), r.dsl);
}

test "ordered list" {
    const r = try renderWith("1. one\n2. two\n");
    try expectEqualStrings("<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n", r.html);
}

test "blockquote" {
    const r = try renderWith("> quote one\n> quote two\n");
    try expectEqualStrings("<blockquote>\n<p>quote one\nquote two</p>\n</blockquote>\n", r.html);
}

test "gfm table" {
    const r = try renderWith("| a | b |\n|---|---|\n| 1 | 2 |\n");
    try expectEqualStrings(
        "<table>\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>\n",
        r.html);
}

test "image with remote url warns and drops src" {
    const r = try renderWith("![alt](https://x.example/i.png)\n");
    try expect(std.mem.indexOf(u8, r.html, "<img alt=\"alt\">") != null);
    try expect(std.mem.indexOf(u8, r.html, "src=") == null);
}

test "fenced code with language" {
    const r = try renderWith("```zig\nconst x = 1;\n```\n");
    try expectEqualStrings("<pre><code class=\"language-zig\">const x = 1;\n</code></pre>\n", r.html);
}

test "cairn-css block is extracted" {
    const r = try renderWith("text\n\n```cairn-css\nh1 { color: red; }\n```\n");
    try expectEqualStrings("h1 { color: red; }", r.css.?);
    try expect(std.mem.indexOf(u8, r.html, "cairn-css") == null);
}

test "second cairn-css block errors" {
    try expectError(error.MultipleStyleBlocks, renderWith("```cairn-css\na{}\n```\n```cairn-css\nb{}\n```\n"));
}
