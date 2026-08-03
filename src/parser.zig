const std = @import("std");
const lexer = @import("lexer.zig");

pub const DomKind = enum { add_class, remove_class, toggle_class, set_text };

pub const DomOp = struct {
    kind: DomKind,
    class: []const u8,
    selector: []const u8,
};

pub const ExtractOp = struct {
    selector: []const u8,
    var_name: []const u8,
};

pub const IfStmt = struct {
    var_name: []const u8,
    value: []const u8,
    body: []Action,
};

pub const Action = union(enum) {
    dom: DomOp,
    extract: ExtractOp,
    if_stmt: IfStmt,
};

pub const Binding = struct {
    event: []const u8,
    selector: []const u8,
    body: []Action,
};

pub const Program = struct {
    bindings: []Binding,
};

pub const Diagnostic = struct {
    line: u32,
    col: u32,
    msg: []const u8,
};

pub const ParseError = error{
    ExpectedKeyword,
    ExpectedString,
    ExpectedLBrace,
    ExpectedRBrace,
    ExpectedEqEq,
    UnknownKeyword,
    UnterminatedString,
    InvalidCharacter,
    OutOfMemory,
};

const events = [_][]const u8{ "click", "hover", "input", "load" };
const dom_kinds = [_]struct { name: []const u8, kind: DomKind }{
    .{ .name = "add_class", .kind = .add_class },
    .{ .name = "remove_class", .kind = .remove_class },
    .{ .name = "toggle_class", .kind = .toggle_class },
    .{ .name = "set_text", .kind = .set_text },
};

fn isEvent(name: []const u8) bool {
    for (events) |e| if (std.mem.eql(u8, name, e)) return true;
    return false;
}

fn domKind(name: []const u8) ?DomKind {
    for (dom_kinds) |d| if (std.mem.eql(u8, name, d.name)) return d.kind;
    return null;
}

fn setDiag(diag: *?Diagnostic, line: u32, col: u32, msg: []const u8) void {
    diag.* = .{ .line = line, .col = col, .msg = msg };
}

fn failTok(diag: *?Diagnostic, tok: lexer.Token, err: ParseError, comptime msg: []const u8) ParseError {
    setDiag(diag, tok.line, tok.col, msg);
    return err;
}

fn nextTok(lex: *lexer.Lexer, diag: *?Diagnostic) ParseError!lexer.Token {
    return lex.next() catch |e| switch (e) {
        error.UnterminatedString => {
            setDiag(diag, lex.err_line, lex.err_col, "unterminated string");
            return error.UnterminatedString;
        },
        error.InvalidCharacter => {
            setDiag(diag, lex.err_line, lex.err_col, "invalid character");
            return error.InvalidCharacter;
        },
    };
}

fn expectString(allocator: std.mem.Allocator, lex: *lexer.Lexer, diag: *?Diagnostic) ParseError![]const u8 {
    const tok = try nextTok(lex, diag);
    if (tok.type != .string) {
        setDiag(diag, tok.line, tok.col, "expected a quoted string");
        return error.ExpectedString;
    }
    return unescape(allocator, tok.text);
}

fn expectKeyword(lex: *lexer.Lexer, comptime word: []const u8, diag: *?Diagnostic) ParseError!void {
    const tok = try nextTok(lex, diag);
    if (tok.type != .keyword or !std.mem.eql(u8, tok.text, word)) {
        setDiag(diag, tok.line, tok.col, "expected `" ++ word ++ "`");
        return error.ExpectedKeyword;
    }
}

fn expectLBrace(lex: *lexer.Lexer, diag: *?Diagnostic) ParseError!void {
    const tok = try nextTok(lex, diag);
    if (tok.type != .lbrace) {
        setDiag(diag, tok.line, tok.col, "expected `{`");
        return error.ExpectedLBrace;
    }
}

fn expectKeywordTok(allocator: std.mem.Allocator, lex: *lexer.Lexer, diag: *?Diagnostic) ParseError![]const u8 {
    const tok = try nextTok(lex, diag);
    if (tok.type != .keyword) {
        setDiag(diag, tok.line, tok.col, "expected a name");
        return error.ExpectedKeyword;
    }
    return allocator.dupe(u8, tok.text);
}

fn expectEqEq(lex: *lexer.Lexer, diag: *?Diagnostic) ParseError!void {
    const tok = try nextTok(lex, diag);
    if (tok.type != .eqeq) {
        setDiag(diag, tok.line, tok.col, "expected `==`");
        return error.ExpectedEqEq;
    }
}

fn unescape(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len and (raw[i + 1] == '"' or raw[i + 1] == '\\')) {
            try out.append(allocator, raw[i + 1]);
            i += 2;
        } else {
            try out.append(allocator, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendAction(allocator: std.mem.Allocator, list: *std.ArrayList(Action), tok: lexer.Token, lex: *lexer.Lexer, diag: *?Diagnostic) ParseError!void {
    if (std.mem.eql(u8, tok.text, "if")) {
        const vn = try expectKeywordTok(allocator, lex, diag);
        try expectEqEq(lex, diag);
        const val = try expectString(allocator, lex, diag);
        try expectLBrace(lex, diag);
        const body = try parseActionBlock(allocator, lex, diag);
        try list.append(allocator, .{ .if_stmt = .{ .var_name = vn, .value = val, .body = body } });
        return;
    }
    if (std.mem.eql(u8, tok.text, "extract_text")) {
        const sel = try expectString(allocator, lex, diag);
        try expectKeyword(lex, "to", diag);
        const vn = try expectKeywordTok(allocator, lex, diag);
        try list.append(allocator, .{ .extract = .{ .selector = sel, .var_name = vn } });
        return;
    }
    const kind = domKind(tok.text) orelse return failTok(diag, tok, error.UnknownKeyword, "unknown action");
    const class = try expectString(allocator, lex, diag);
    try expectKeyword(lex, "on", diag);
    const sel = try expectString(allocator, lex, diag);
    try list.append(allocator, .{ .dom = .{ .kind = kind, .class = class, .selector = sel } });
}

fn parseActionBlock(allocator: std.mem.Allocator, lex: *lexer.Lexer, diag: *?Diagnostic) ParseError![]Action {
    var body: std.ArrayList(Action) = .empty;
    errdefer body.deinit(allocator);
    while (true) {
        const t = try nextTok(lex, diag);
        if (t.type == .rbrace) return body.toOwnedSlice(allocator);
        if (t.type == .semicolon) continue;
        if (t.type == .eof) {
            setDiag(diag, t.line, t.col, "missing `}`");
            return error.ExpectedRBrace;
        }
        if (t.type != .keyword) return failTok(diag, t, error.ExpectedKeyword, "expected action");
        try appendAction(allocator, &body, t, lex, diag);
    }
}

/// The allocator is expected to be an arena (or other leak-tolerant
/// allocator): on error, AST slices allocated before the failing token
/// are not freed (only the bindings buffer is errdefer'd); on success,
/// all AST memory is owned by the caller's allocator.
pub fn parse(allocator: std.mem.Allocator, src: []const u8, diag: *?Diagnostic) ParseError!Program {
    var lex = lexer.Lexer{ .src = src };
    var bindings: std.ArrayList(Binding) = .empty;
    errdefer bindings.deinit(allocator);

    while (true) {
        const tok = try nextTok(&lex, diag);
        if (tok.type == .eof) break;
        if (tok.type == .semicolon) continue;
        if (tok.type != .keyword) return failTok(diag, tok, error.ExpectedKeyword, "expected `on`");
        if (!std.mem.eql(u8, tok.text, "on")) return failTok(diag, tok, error.ExpectedKeyword, "expected `on`");
        const ev_tok = try nextTok(&lex, diag);
        if (ev_tok.type != .keyword or !isEvent(ev_tok.text)) {
            return failTok(diag, ev_tok, error.UnknownKeyword, "unknown event type");
        }
        const event = try allocator.dupe(u8, ev_tok.text);
        const sel = try expectString(allocator, &lex, diag);
        try expectLBrace(&lex, diag);
        const body = try parseActionBlock(allocator, &lex, diag);
        try bindings.append(allocator, .{ .event = event, .selector = sel, .body = body });
    }
    return .{ .bindings = try bindings.toOwnedSlice(allocator) };
}

const parser = @import("parser.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

fn parseWith(src: []const u8) !parser.Program {
    // arena is intentionally leaked (page_allocator: no leak detection);
    // deinit here would free the returned AST before the test reads it
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var diag: ?parser.Diagnostic = null;
    return parser.parse(arena.allocator(), src, &diag);
}

test "parses event binding with set_text" {
    const prog = try parseWith("on click \"#b\" { set_text \"hello\" on \"#o\"; }");
    try expectEqual(@as(usize, 1), prog.bindings.len);
    const b = prog.bindings[0];
    try expectEqualStrings("click", b.event);
    try expectEqualStrings("#b", b.selector);
    try expectEqual(@as(usize, 1), b.body.len);
    const act = b.body[0];
    try expect(std.meta.activeTag(act) == .dom);
    try expectEqual(act.dom.kind, .set_text);
    try expectEqualStrings("hello", act.dom.class);
    try expectEqualStrings("#o", act.dom.selector);
}

test "parses extract_text and if" {
    const prog = try parseWith("on click \"#g\" { extract_text \"#s\" to v; if v == \"yes\" { set_text \"hit\" on \"#d\"; } }");
    const body = prog.bindings[0].body;
    try expectEqual(@as(usize, 2), body.len);
    try expect(std.meta.activeTag(body[0]) == .extract);
    try expectEqualStrings("#s", body[0].extract.selector);
    try expectEqualStrings("v", body[0].extract.var_name);
    try expect(std.meta.activeTag(body[1]) == .if_stmt);
    try expectEqualStrings("v", body[1].if_stmt.var_name);
    try expectEqualStrings("yes", body[1].if_stmt.value);
    try expectEqual(@as(usize, 1), body[1].if_stmt.body.len);
}

test "parses multiple bindings with semicolons" {
    const prog = try parseWith("on hover \"#a\" { add_class \"k\" on \"#a\"; }; on load \"#b\" { toggle_class \"on\" on \"#b\" }");
    try expectEqual(@as(usize, 2), prog.bindings.len);
    try expectEqualStrings("hover", prog.bindings[0].event);
    try expectEqualStrings("load", prog.bindings[1].event);
}

test "string escapes are unescaped" {
    const prog = try parseWith("on click \"#b\" { set_text \"a\\\"b\" on \"#o\"; }");
    try expectEqualStrings("a\"b", prog.bindings[0].body[0].dom.class);
}

test "missing brace is a parse error with diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var diag: ?parser.Diagnostic = null;
    try expectError(error.ExpectedRBrace, parser.parse(arena.allocator(), "on click \"#b\" { set_text \"x\" on \"#o\"", &diag));
    try expect(diag != null);
    try expectEqual(@as(u32, 1), diag.?.line);
}

test "unknown action keyword is rejected" {
    try expectError(error.UnknownKeyword, parseWith("on click \"#b\" { frobnicate \"x\" on \"#o\"; }"));
}

test "unknown event type is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var diag: ?parser.Diagnostic = null;
    try expectError(error.UnknownKeyword, parser.parse(arena.allocator(), "on dblclick \"#b\" { }", &diag));
    try expect(diag != null);
    try expectEqual(@as(u32, 1), diag.?.line);
}

test "top-level non-on keyword is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var diag: ?parser.Diagnostic = null;
    try expectError(error.ExpectedKeyword, parser.parse(arena.allocator(), "frobnicate \"#b\" { }", &diag));
    try expect(diag != null);
}

test "empty program has zero bindings" {
    const prog = try parseWith("");
    try expectEqual(@as(usize, 0), prog.bindings.len);
}

test "event-name slot with a string is rejected" {
    try expectError(error.UnknownKeyword, parseWith("on \"#b\" { }"));
}
