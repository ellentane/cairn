const std = @import("std");
const markdown = @import("markdown.zig"); // self-import for tests

pub const MarkdownError = error{ MultipleCairnBlocks, OutOfMemory };

pub const RenderResult = struct {
    html: []u8,
    dsl: ?[]const u8,
    /// 1-based line number of the first line inside the cairn fence
    /// (fence opener line + 1) in the source file; 0 when no cairn block.
    dsl_line_offset: u32,
    /// First H1 in document order (raw HTML passthrough included), or null.
    title: ?[]const u8,
};

const MarkdownParser = struct {
    allocator: std.mem.Allocator,
    html: std.ArrayList(u8),
    para: std.ArrayList([]const u8),
    list: std.ArrayList([]const u8),
    in_pre: bool,
    dsl: ?[]const u8,
    dsl_line_offset: u32,
    title: ?[]const u8,

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
            try renderInline(self.allocator, &self.html, line);
        }
        try self.html.appendSlice(self.allocator, "</p>\n");
        self.para.clearRetainingCapacity();
    }

    fn flushList(self: *MarkdownParser) !void {
        if (self.list.items.len == 0) return;
        try self.html.appendSlice(self.allocator, "<ul>\n");
        for (self.list.items) |item| {
            try self.html.appendSlice(self.allocator, "<li>");
            try renderInline(self.allocator, &self.html, item);
            try self.html.appendSlice(self.allocator, "</li>\n");
        }
        try self.html.appendSlice(self.allocator, "</ul>\n");
        self.list.clearRetainingCapacity();
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
            errdefer buf.deinit(self.allocator);
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
        self.in_pre = true;
        try self.html.appendSlice(self.allocator, "<pre><code>");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "```")) {
                self.in_pre = false;
                try self.html.appendSlice(self.allocator, "</code></pre>\n");
                return;
            }
            try appendEscaped(self.allocator, &self.html, line);
            try self.html.append(self.allocator, '\n');
        }
    }
};

fn isBlank(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t') return false;
    return true;
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
        else => try buf.append(allocator, c),
    };
}

fn renderInline(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '<') {
            if (std.mem.indexOfScalarPos(u8, text, i, '>')) |end| {
                try buf.appendSlice(allocator, text[i .. end + 1]);
                i = end + 1;
                continue;
            }
            try buf.appendSlice(allocator, "&lt;");
            i += 1;
            continue;
        }
        if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            const rest = text[i + 2 ..];
            if (std.mem.indexOf(u8, rest, "**")) |end| {
                try buf.appendSlice(allocator, "<strong>");
                try renderInline(allocator, buf, rest[0..end]);
                try buf.appendSlice(allocator, "</strong>");
                i += 2 + end + 2;
                continue;
            }
        }
        if (c == '*') {
            const rest = text[i + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '*')) |end| {
                try buf.appendSlice(allocator, "<em>");
                try renderInline(allocator, buf, rest[0..end]);
                try buf.appendSlice(allocator, "</em>");
                i += 1 + end + 1;
                continue;
            }
        }
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close| {
                if (close + 1 < text.len and text[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |paren| {
                        const href = text[close + 2 .. paren];
                        try buf.appendSlice(allocator, "<a href=\"");
                        try appendEscaped(allocator, buf, href);
                        try buf.appendSlice(allocator, "\">");
                        try renderInline(allocator, buf, text[i + 1 .. close]);
                        try buf.appendSlice(allocator, "</a>");
                        i = paren + 1;
                        continue;
                    }
                }
            }
        }
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            else => try buf.append(allocator, c),
        }
        i += 1;
    }
}

pub fn renderAll(allocator: std.mem.Allocator, src: []const u8) MarkdownError!RenderResult {
    var p = MarkdownParser{
        .allocator = allocator,
        .html = .empty,
        .para = .empty,
        .list = .empty,
        .in_pre = false,
        .dsl = null,
        .dsl_line_offset = 0,
        .title = null,
    };
    errdefer p.html.deinit(allocator);

    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.startsWith(u8, line, "```")) {
            try p.flushPara();
            try p.flushList();
            try p.handleFence(line, line_no, &lines);
            continue;
        }
        if (line.len > 0 and line[0] == '#' and line.len > 1 and (line[1] == ' ' or line[1] == '#')) {
            try p.flushPara();
            try p.flushList();
            var level: usize = 1;
            while (level < line.len and level < 6 and line[level] == '#') level += 1;
            const text = line[level..];
            if (level == 1) try p.setTitle(text);
            try p.html.appendSlice(allocator, "<h");
            try appendNum(allocator, &p.html, level);
            try p.html.appendSlice(allocator, ">");
            try renderInline(allocator, &p.html, std.mem.trim(u8, text, " \t"));
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
        if (line.len > 1 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
            try p.flushPara();
            try p.list.append(allocator, line[2..]);
            continue;
        }
        if (isBlank(line)) {
            try p.flushPara();
            try p.flushList();
            continue;
        }
        try p.flushList();
        try p.para.append(allocator, line);
    }
    try p.flushPara();
    try p.flushList();

    return .{
        .html = try p.html.toOwnedSlice(allocator),
        .dsl = p.dsl,
        .dsl_line_offset = p.dsl_line_offset,
        .title = p.title,
    };
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

fn renderWith(src: []const u8) !markdown.RenderResult {
    // arena intentionally leaked (page_allocator); deinit would free the result
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return markdown.renderAll(arena.allocator(), src);
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
    try expectEqualStrings("<pre><code>if (a &lt; b) {}\n</code></pre>\n", r.html);
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

test "h2 through h6 headings" {
    const r = try renderWith("## sub\n\n### mid\n\n###### six\n");
    try expectEqualStrings("<h2>sub</h2>\n<h3>mid</h3>\n<h6>six</h6>\n", r.html);
    try expectEqual(@as(?[]const u8, null), r.title); // h1 only sets title
}
