const std = @import("std");
const lexer = @import("lexer.zig");

pub const DomKind = enum { add_class, remove_class, toggle_class, set_text };

pub const DomOp = struct {
    kind: DomKind,
    class: []const u8,
    selector: []const u8,
};

pub const BinOp = enum { add, sub };

pub const Expr = union(enum) {
    lit: []const u8, // string or number literal (values are strings)
    var_ref: []const u8,
    binary: struct {
        op: BinOp,
        lhs: *Expr,
        rhs: *Expr,
    },
};

pub const CmpOp = enum { eq, ne, lt, gt, le, ge };

pub const Cond = struct {
    var_name: []const u8,
    op: CmpOp,
    rhs: Expr,
};

pub const ExtractOp = struct { selector: []const u8, var_name: []const u8 };
pub const IncStmt = []const u8; // var name
pub const SetTextExpr = struct { expr: Expr, selector: []const u8 };

pub const IfStmt = struct {
    cond: Cond,
    body: []Action,
    else_body: ?[]Action,
};

pub const WhileStmt = struct {
    cond: Cond,
    body: []Action,
};

pub const Action = union(enum) {
    dom: DomOp,
    set_text_expr: SetTextExpr,
    extract: ExtractOp,
    extract_value: ExtractOp,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    inc_stmt: IncStmt,
};

pub const Assignment = struct {
    var_name: []const u8,
    expr: Expr,
};

pub const Statement = union(enum) {
    binding: Binding,
    assignment: Assignment,
};

pub const Binding = struct {
    event: []const u8,
    selector: []const u8,
    body: []Action,
};

pub const Program = struct {
    statements: []Statement,
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
    ExpectedEquals,
    UnknownKeyword,
    UnterminatedString,
    InvalidCharacter,
    OutOfMemory,
};

const events = [_][]const u8{ "click", "hover", "input", "load", "focus", "blur", "keydown", "keyup", "change", "submit", "dblclick" };
const dom_kinds = [_]struct { name: []const u8, kind: DomKind }{
    .{ .name = "add_class", .kind = .add_class },
    .{ .name = "remove_class", .kind = .remove_class },
    .{ .name = "toggle_class", .kind = .toggle_class },
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

fn expectEquals(lex: *lexer.Lexer, diag: *?Diagnostic) ParseError!void {
    const tok = try nextTok(lex, diag);
    if (tok.type != .equals) {
        setDiag(diag, tok.line, tok.col, "expected `=`");
        return error.ExpectedEquals;
    }
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

fn parseTerm(allocator: std.mem.Allocator, lex: *lexer.Lexer, diag: *?Diagnostic) ParseError!Expr {
    const tok = try nextTok(lex, diag);
    switch (tok.type) {
        .string => return .{ .lit = try unescape(allocator, tok.text) },
        .number => return .{ .lit = try allocator.dupe(u8, tok.text) },
        .keyword => return .{ .var_ref = try allocator.dupe(u8, tok.text) },
        else => {
            setDiag(diag, tok.line, tok.col, "expected a value");
            return error.ExpectedString;
        },
    }
}

fn parseExpr(allocator: std.mem.Allocator, lex: *lexer.Lexer, diag: *?Diagnostic) ParseError!Expr {
    var lhs = try parseTerm(allocator, lex, diag);
    while (true) {
        const tok = try nextTok(lex, diag);
        const op: BinOp = switch (tok.type) {
            .plus => .add,
            .minus => .sub,
            else => {
                lex.pushback = tok; // one-token lookahead
                return lhs;
            },
        };
        const rhs = try parseTerm(allocator, lex, diag);
        const boxed_lhs = try allocator.create(Expr);
        boxed_lhs.* = lhs;
        const boxed_rhs = try allocator.create(Expr);
        boxed_rhs.* = rhs;
        lhs = .{ .binary = .{ .op = op, .lhs = boxed_lhs, .rhs = boxed_rhs } };
    }
}

fn parseCond(allocator: std.mem.Allocator, lex: *lexer.Lexer, diag: *?Diagnostic) ParseError!Cond {
    const vn = try expectKeywordTok(allocator, lex, diag);
    const tok = try nextTok(lex, diag);
    const op: CmpOp = switch (tok.type) {
        .eqeq => .eq,
        .neq => .ne,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        else => {
            setDiag(diag, tok.line, tok.col, "expected a comparison operator");
            return error.ExpectedEqEq;
        },
    };
    return .{ .var_name = vn, .op = op, .rhs = try parseTerm(allocator, lex, diag) };
}

fn appendAction(allocator: std.mem.Allocator, list: *std.ArrayList(Action), tok: lexer.Token, lex: *lexer.Lexer, diag: *?Diagnostic) ParseError!void {
    if (std.mem.eql(u8, tok.text, "extract_text") or std.mem.eql(u8, tok.text, "extract_value")) {
        const sel = try expectString(allocator, lex, diag);
        try expectKeyword(lex, "to", diag);
        const vn = try expectKeywordTok(allocator, lex, diag);
        try list.append(allocator, if (std.mem.eql(u8, tok.text, "extract_value"))
            .{ .extract_value = .{ .selector = sel, .var_name = vn } }
        else
            .{ .extract = .{ .selector = sel, .var_name = vn } });
        return;
    }
    if (std.mem.eql(u8, tok.text, "inc")) {
        const vn = try expectKeywordTok(allocator, lex, diag);
        try list.append(allocator, .{ .inc_stmt = vn });
        return;
    }
    if (std.mem.eql(u8, tok.text, "if")) {
        const cond = try parseCond(allocator, lex, diag);
        try expectLBrace(lex, diag);
        const body = try parseActionBlock(allocator, lex, diag);
        var else_body: ?[]Action = null;
        const t = try nextTok(lex, diag);
        if (t.type == .keyword and std.mem.eql(u8, t.text, "else")) {
            try expectLBrace(lex, diag);
            else_body = try parseActionBlock(allocator, lex, diag);
        } else {
            lex.pushback = t;
        }
        try list.append(allocator, .{ .if_stmt = .{ .cond = cond, .body = body, .else_body = else_body } });
        return;
    }
    if (std.mem.eql(u8, tok.text, "while")) {
        const cond = try parseCond(allocator, lex, diag);
        try expectLBrace(lex, diag);
        const body = try parseActionBlock(allocator, lex, diag);
        try list.append(allocator, .{ .while_stmt = .{ .cond = cond, .body = body } });
        return;
    }
    if (std.mem.eql(u8, tok.text, "set_text")) {
        const expr = try parseExpr(allocator, lex, diag);
        try expectKeyword(lex, "on", diag);
        const sel = try expectString(allocator, lex, diag);
        try list.append(allocator, .{ .set_text_expr = .{ .expr = expr, .selector = sel } });
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

pub fn parse(allocator: std.mem.Allocator, src: []const u8, diag: *?Diagnostic) ParseError!Program {
    var lex = lexer.Lexer{ .src = src };
    var statements: std.ArrayList(Statement) = .empty;
    errdefer statements.deinit(allocator);

    while (true) {
        const tok = try nextTok(&lex, diag);
        if (tok.type == .eof) break;
        if (tok.type == .semicolon) continue;
        if (tok.type != .keyword) return failTok(diag, tok, error.ExpectedKeyword, "expected statement");
        if (std.mem.eql(u8, tok.text, "let")) {
            const vn = try expectKeywordTok(allocator, &lex, diag);
            try expectEquals(&lex, diag);
            const expr = try parseExpr(allocator, &lex, diag);
            try statements.append(allocator, .{ .assignment = .{ .var_name = vn, .expr = expr } });
            continue;
        }
        if (!std.mem.eql(u8, tok.text, "on")) return failTok(diag, tok, error.ExpectedKeyword, "expected `on`");
        const ev_tok = try nextTok(&lex, diag);
        if (ev_tok.type != .keyword or !isEvent(ev_tok.text)) {
            setDiag(diag, ev_tok.line, ev_tok.col, "unknown event type");
            return error.UnknownKeyword;
        }
        const event = try allocator.dupe(u8, ev_tok.text);
        const sel = try expectString(allocator, &lex, diag);
        try expectLBrace(&lex, diag);
        const body = try parseActionBlock(allocator, &lex, diag);
        try statements.append(allocator, .{ .binding = .{ .event = event, .selector = sel, .body = body } });
    }
    return .{ .statements = try statements.toOwnedSlice(allocator) };
}

const parser = @import("parser.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

fn parseWith(src: []const u8) !parser.Program {
    // leaked-arena pattern (page_allocator, no deinit) — see v0.1 plan Task 2
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var diag: ?parser.Diagnostic = null;
    return parser.parse(arena.allocator(), src, &diag);
}

fn bindingOf(p: parser.Program, i: usize) parser.Binding {
    return p.statements[i].binding;
}

test "top-level let assignment and inc" {
    const prog = try parseWith("let c = 0; on click \"#b\" { inc c; }");
    try expectEqual(@as(usize, 2), prog.statements.len);
    try expect(std.meta.activeTag(prog.statements[0]) == .assignment);
    try expectEqualStrings("c", prog.statements[0].assignment.var_name);
    try expect(std.meta.activeTag(prog.statements[1]) == .binding);
    const body = prog.statements[1].binding.body;
    try expect(std.meta.activeTag(body[0]) == .inc_stmt);
    try expectEqualStrings("c", body[0].inc_stmt);
}

test "expression with add and subtract" {
    const prog = try parseWith("let v = 1 + count - 2;");
    const e = prog.statements[0].assignment.expr;
    try expect(std.meta.activeTag(e) == .binary);
    try expectEqual(e.binary.op, .sub);
    try expect(std.meta.activeTag(e.binary.rhs.*) == .lit);
    try expectEqualStrings("2", e.binary.rhs.*.lit);
    const inner = e.binary.lhs.*;
    try expectEqual(inner.binary.op, .add);
    try expect(std.meta.activeTag(inner.binary.rhs.*) == .var_ref);
    try expectEqualStrings("count", inner.binary.rhs.*.var_ref);
}

test "if with else and while" {
    const prog = try parseWith("on click \"#b\" { if c == \"1\" { inc c; } else { inc c; } while c < 3 { inc c; } }");
    const body = prog.statements[0].binding.body;
    try expectEqual(@as(usize, 2), body.len);
    try expect(std.meta.activeTag(body[0]) == .if_stmt);
    try expect(body[0].if_stmt.else_body != null);
    try expectEqual(@as(usize, 1), body[0].if_stmt.else_body.?.len);
    try expect(std.meta.activeTag(body[1]) == .while_stmt);
    try expectEqual(body[1].while_stmt.cond.op, .lt);
}

test "set_text with expression and extract_value" {
    const prog = try parseWith("on click \"#b\" { set_text count + 1 on \"#o\"; extract_value \"#i\" to v; }");
    const body = prog.statements[0].binding.body;
    try expect(std.meta.activeTag(body[0]) == .set_text_expr);
    try expectEqualStrings("#o", body[0].set_text_expr.selector);
    try expect(std.meta.activeTag(body[0].set_text_expr.expr) == .binary);
    try expect(std.meta.activeTag(body[1]) == .extract_value);
    try expectEqualStrings("v", body[1].extract_value.var_name);
}

test "expanded event types parse" {
    const prog = try parseWith("on keydown \"#i\" { } on submit \"#f\" { }");
    try expectEqualStrings("keydown", prog.statements[0].binding.event);
    try expectEqualStrings("submit", prog.statements[1].binding.event);
}

test "number literal and var operands in cond" {
    const prog = try parseWith("on load \"#w\" { while n < limit { inc n; } }");
    const cond = prog.statements[0].binding.body[0].while_stmt.cond;
    try expect(std.meta.activeTag(cond.rhs) == .var_ref);
    try expectEqualStrings("limit", cond.rhs.var_ref);
}

test "parses event binding with set_text" {
    const prog = try parseWith("on click \"#b\" { set_text \"hello\" on \"#o\"; }");
    try expectEqual(@as(usize, 1), prog.statements.len);
    const b = bindingOf(prog, 0);
    try expectEqualStrings("click", b.event);
    try expectEqualStrings("#b", b.selector);
    try expectEqual(@as(usize, 1), b.body.len);
    const act = b.body[0];
    try expect(std.meta.activeTag(act) == .set_text_expr);
    try expect(std.meta.activeTag(act.set_text_expr.expr) == .lit);
    try expectEqualStrings("hello", act.set_text_expr.expr.lit);
    try expectEqualStrings("#o", act.set_text_expr.selector);
}

test "parses extract_text and if" {
    const prog = try parseWith("on click \"#g\" { extract_text \"#s\" to v; if v == \"yes\" { set_text \"hit\" on \"#d\"; } }");
    const body = bindingOf(prog, 0).body;
    try expectEqual(@as(usize, 2), body.len);
    try expect(std.meta.activeTag(body[0]) == .extract);
    try expectEqualStrings("#s", body[0].extract.selector);
    try expectEqualStrings("v", body[0].extract.var_name);
    try expect(std.meta.activeTag(body[1]) == .if_stmt);
    try expectEqualStrings("v", body[1].if_stmt.cond.var_name);
    try expectEqualStrings("yes", body[1].if_stmt.cond.rhs.lit);
    try expectEqual(@as(usize, 1), body[1].if_stmt.body.len);
}

test "parses multiple bindings with semicolons" {
    const prog = try parseWith("on hover \"#a\" { add_class \"k\" on \"#a\"; }; on load \"#b\" { toggle_class \"on\" on \"#b\" }");
    try expectEqual(@as(usize, 2), prog.statements.len);
    try expectEqualStrings("hover", bindingOf(prog, 0).event);
    try expectEqualStrings("load", bindingOf(prog, 1).event);
}

test "string escapes are unescaped" {
    const prog = try parseWith("on click \"#b\" { set_text \"a\\\"b\" on \"#o\"; }");
    try expectEqualStrings("a\"b", bindingOf(prog, 0).body[0].set_text_expr.expr.lit);
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
    try expectError(error.UnknownKeyword, parser.parse(arena.allocator(), "on keypress \"#b\" { }", &diag));
    try expect(diag != null);
    try expectEqual(@as(u32, 1), diag.?.line);
}

test "top-level non-on keyword is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var diag: ?parser.Diagnostic = null;
    try expectError(error.ExpectedKeyword, parser.parse(arena.allocator(), "frobnicate \"#b\" { }", &diag));
    try expect(diag != null);
}

test "empty program has zero statements" {
    const prog = try parseWith("");
    try expectEqual(@as(usize, 0), prog.statements.len);
}

test "event-name slot with a string is rejected" {
    try expectError(error.UnknownKeyword, parseWith("on \"#b\" { }"));
}
