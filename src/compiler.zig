const std = @import("std");
const parser = @import("parser.zig");

pub const CompileError = error{ BytecodeTooLarge, OutOfMemory };

pub const op = struct {
    pub const PUSH_STR: u8 = 0x01;
    pub const PUSH_SELECTOR: u8 = 0x02;
    pub const GET_NODES: u8 = 0x03;
    pub const ADD_CLASS: u8 = 0x04;
    pub const REMOVE_CLASS: u8 = 0x05;
    pub const TOGGLE_CLASS: u8 = 0x06;
    pub const SET_TEXT: u8 = 0x07;
    pub const ON_EVENT: u8 = 0x08;
    pub const JUMP: u8 = 0x09;
    pub const HALT: u8 = 0x0A;
    pub const EXTRACT_TEXT: u8 = 0x0B;
    pub const PUSH_VAR: u8 = 0x0C;
    pub const CMP_STR: u8 = 0x0D;
    pub const JMP_IF_FALSE: u8 = 0x0E;
    pub const STORE_VAR: u8 = 0x0F;
    pub const INC: u8 = 0x10;
    pub const ADD_NUM: u8 = 0x11;
    pub const SUB_NUM: u8 = 0x12;
    pub const CMP_EQ: u8 = 0x13;
    pub const CMP_NE: u8 = 0x14;
    pub const CMP_LT: u8 = 0x15;
    pub const CMP_GT: u8 = 0x16;
    pub const CMP_LE: u8 = 0x17;
    pub const CMP_GE: u8 = 0x18;
    pub const JMP_IF_TRUE: u8 = 0x19;
    pub const SET_TEXT_POP: u8 = 0x1A;
    pub const EXTRACT_VALUE: u8 = 0x1B;
};

pub fn eventNameFor(evt: []const u8) []const u8 {
    return if (std.mem.eql(u8, evt, "hover")) "mouseenter" else evt;
}

fn appendStr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len > std.math.maxInt(u16)) return error.BytecodeTooLarge;
    const n: u16 = @intCast(s.len);
    const lo: u8 = @truncate(n);
    const hi: u8 = @truncate(n >> 8);
    try buf.appendSlice(allocator, &.{ lo, hi });
    try buf.appendSlice(allocator, s);
}

fn domOpcode(kind: parser.DomKind) u8 {
    return switch (kind) {
        .add_class => op.ADD_CLASS,
        .remove_class => op.REMOVE_CLASS,
        .toggle_class => op.TOGGLE_CLASS,
        .set_text => op.SET_TEXT,
    };
}

pub fn compile(allocator: std.mem.Allocator, prog: parser.Program) CompileError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var addr_slots: std.ArrayList(usize) = .empty;
    errdefer addr_slots.deinit(allocator);
    var block_starts: std.ArrayList(usize) = .empty;
    errdefer block_starts.deinit(allocator);

    for (prog.statements) |st| switch (st) {
        .assignment => |a| {
            try emitExpr(allocator, &buf, a.expr);
            try buf.append(allocator, op.STORE_VAR);
            try appendStr(allocator, &buf, a.var_name);
        },
        .binding => |b| {
            try buf.append(allocator, op.PUSH_SELECTOR);
            try appendStr(allocator, &buf, b.selector);
            try buf.append(allocator, op.GET_NODES);
            try buf.append(allocator, op.ON_EVENT);
            try appendStr(allocator, &buf, eventNameFor(b.event));
            const slot = buf.items.len;
            try buf.appendSlice(allocator, &.{ 0, 0 });
            try addr_slots.append(allocator, slot);
        },
    };
    try buf.append(allocator, op.HALT);

    for (prog.statements) |st| switch (st) {
        .binding => |b| {
            try block_starts.append(allocator, buf.items.len);
            for (b.body) |a| try emitAction(allocator, &buf, a);
            try buf.append(allocator, op.HALT); // trailing block terminator: handlers must not run into the next block
        },
        .assignment => {},
    };

    if (buf.items.len > std.math.maxInt(u16) + 1) return error.BytecodeTooLarge;
    for (addr_slots.items, 0..) |slot, idx| {
        const addr: u16 = @intCast(block_starts.items[idx]);
        buf.items[slot] = @truncate(addr);
        buf.items[slot + 1] = @truncate(addr >> 8);
    }
    return buf.toOwnedSlice(allocator);
}

fn emitExpr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), expr: parser.Expr) !void {
    switch (expr) {
        .lit => |s| {
            try buf.append(allocator, op.PUSH_STR);
            try appendStr(allocator, buf, s);
        },
        .var_ref => |v| {
            try buf.append(allocator, op.PUSH_VAR);
            try appendStr(allocator, buf, v);
        },
        .binary => |bin| {
            try emitExpr(allocator, buf, bin.lhs.*);
            try emitExpr(allocator, buf, bin.rhs.*);
            try buf.append(allocator, if (bin.op == .add) op.ADD_NUM else op.SUB_NUM);
        },
    }
}

fn cmpOpcode(cmp: parser.CmpOp) u8 {
    return switch (cmp) {
        .eq => op.CMP_EQ,
        .ne => op.CMP_NE,
        .lt => op.CMP_LT,
        .gt => op.CMP_GT,
        .le => op.CMP_LE,
        .ge => op.CMP_GE,
    };
}

fn emitCond(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), cond: parser.Cond) !void {
    try buf.append(allocator, op.PUSH_VAR);
    try appendStr(allocator, buf, cond.var_name);
    try emitExpr(allocator, buf, cond.rhs);
    try buf.append(allocator, cmpOpcode(cond.op));
}

fn patch16(buf: *std.ArrayList(u8), slot: usize) error{BytecodeTooLarge}!void {
    if (buf.items.len > std.math.maxInt(u16)) return error.BytecodeTooLarge;
    const target: u16 = @intCast(buf.items.len);
    buf.items[slot] = @truncate(target);
    buf.items[slot + 1] = @truncate(target >> 8);
}

fn emitAction(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), action: parser.Action) !void {
    switch (action) {
        .dom => |dom| {
            try buf.append(allocator, op.PUSH_SELECTOR);
            try appendStr(allocator, buf, dom.selector);
            try buf.append(allocator, op.GET_NODES);
            try buf.append(allocator, domOpcode(dom.kind));
            try appendStr(allocator, buf, dom.class);
        },
        .set_text_expr => |stx| {
            if (stx.expr == .lit) {
                // peephole: literal set_text keeps the v0.1 byte form
                try buf.append(allocator, op.PUSH_SELECTOR);
                try appendStr(allocator, buf, stx.selector);
                try buf.append(allocator, op.GET_NODES);
                try buf.append(allocator, op.SET_TEXT);
                try appendStr(allocator, buf, stx.expr.lit);
            } else {
                try emitExpr(allocator, buf, stx.expr);
                try buf.append(allocator, op.PUSH_SELECTOR);
                try appendStr(allocator, buf, stx.selector);
                try buf.append(allocator, op.GET_NODES);
                try buf.append(allocator, op.SET_TEXT_POP);
            }
        },
        .extract => |ex| {
            try buf.append(allocator, op.PUSH_SELECTOR);
            try appendStr(allocator, buf, ex.selector);
            try buf.append(allocator, op.GET_NODES);
            try buf.append(allocator, op.EXTRACT_TEXT);
            try appendStr(allocator, buf, ex.var_name);
        },
        .extract_value => |ex| {
            try buf.append(allocator, op.PUSH_SELECTOR);
            try appendStr(allocator, buf, ex.selector);
            try buf.append(allocator, op.GET_NODES);
            try buf.append(allocator, op.EXTRACT_VALUE);
            try appendStr(allocator, buf, ex.var_name);
        },
        .inc_stmt => |v| {
            try buf.append(allocator, op.INC);
            try appendStr(allocator, buf, v);
        },
        .if_stmt => |s| {
            try emitCond(allocator, buf, s.cond);
            try buf.append(allocator, op.JMP_IF_FALSE);
            const else_slot = buf.items.len;
            try buf.appendSlice(allocator, &.{ 0, 0 });
            for (s.body) |a| try emitAction(allocator, buf, a);
            if (s.else_body) |else_body| {
                try buf.append(allocator, op.JUMP);
                const end_slot = buf.items.len;
                try buf.appendSlice(allocator, &.{ 0, 0 });
                try patch16(buf, else_slot);
                for (else_body) |a| try emitAction(allocator, buf, a);
                try patch16(buf, end_slot);
            } else {
                try patch16(buf, else_slot);
            }
        },
        .while_stmt => |s| {
            const top = buf.items.len;
            try emitCond(allocator, buf, s.cond);
            try buf.append(allocator, op.JMP_IF_FALSE);
            const end_slot = buf.items.len;
            try buf.appendSlice(allocator, &.{ 0, 0 });
            for (s.body) |a| try emitAction(allocator, buf, a);
            try buf.append(allocator, op.JUMP);
            if (top > std.math.maxInt(u16)) return error.BytecodeTooLarge;
            try appendAddr(allocator, buf, @intCast(top));
            try patch16(buf, end_slot);
        },
    }
}

fn appendAddr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), a: u16) !void {
    try buf.appendSlice(allocator, &.{ @truncate(a), @truncate(a >> 8) });
}

const compiler = @import("compiler.zig");
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

fn compileWith(src: []const u8) ![]u8 {
    // leaked-arena pattern (see v0.1 plan Task 2): page_allocator, no deinit
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var diag: ?parser.Diagnostic = null;
    const prog = try parser.parse(arena.allocator(), src, &diag);
    return compiler.compile(arena.allocator(), prog);
}

test "A: top-level let + inc (vector A)" {
    const bc = try compileWith("let c = 0; on click \"#b\" { inc c; }");
    const expected = [_]u8{ 1, 1, 0, 48, 15, 1, 0, 99, 2, 2, 0, 35, 98, 3, 8, 5, 0, 99, 108, 105, 99, 107, 25, 0, 10, 16, 1, 0, 99, 10 };
    try expectEqualSlices(u8, &expected, bc);
}

test "B: if/else (vector B)" {
    const bc = try compileWith("on click \"#b\" { if c == \"1\" { set_text \"a\" on \"#x\"; } else { set_text \"b\" on \"#x\"; } }");
    const expected = [_]u8{ 2, 2, 0, 35, 98, 3, 8, 5, 0, 99, 108, 105, 99, 107, 17, 0, 10, 12, 1, 0, 99, 1, 1, 0, 49, 19, 14, 42, 0, 2, 2, 0, 35, 120, 3, 7, 1, 0, 97, 9, 52, 0, 2, 2, 0, 35, 120, 3, 7, 1, 0, 98, 10 };
    try expectEqualSlices(u8, &expected, bc);
}

test "C: while loop (vector C)" {
    const bc = try compileWith("on load \"#w\" { while n < 3 { inc n; } }");
    const expected = [_]u8{ 2, 2, 0, 35, 119, 3, 8, 4, 0, 108, 111, 97, 100, 16, 0, 10, 12, 1, 0, 110, 1, 1, 0, 51, 21, 14, 35, 0, 16, 1, 0, 110, 9, 16, 0, 10 };
    try expectEqualSlices(u8, &expected, bc);
}

test "set_text expr and extract_value emit SET_TEXT_POP and EXTRACT_VALUE" {
    const bc = try compileWith("on click \"#b\" { set_text v + 1 on \"#o\"; extract_value \"#i\" to w; }");
    try expect(std.mem.indexOf(u8, bc, &[_]u8{26}) != null); // SET_TEXT_POP present
    try expect(std.mem.indexOf(u8, bc, &[_]u8{27}) != null); // EXTRACT_VALUE present
}

test "comparison operators map to CMP opcodes" {
    const eq = try compileWith("on click \"#b\" { if v != \"x\" { } }");
    try expect(std.mem.indexOf(u8, eq, &[_]u8{20}) != null); // CMP_NE
    const ge = try compileWith("on click \"#b\" { if v >= 5 { } }");
    try expect(std.mem.indexOf(u8, ge, &[_]u8{24}) != null); // CMP_GE
}

test "expanded events pass through" {
    try expectEqualStrings("keydown", compiler.eventNameFor("keydown"));
    try expectEqualStrings("submit", compiler.eventNameFor("submit"));
    try expectEqualStrings("mouseenter", compiler.eventNameFor("hover"));
}

test "V1: single set_text binding (unchanged under v0.2)" {
    const bc = try compileWith("on click \"#btn\" { set_text \"Status: 1\" on \"#out\"; }");
    const expected = [_]u8{ 2, 4, 0, 35, 98, 116, 110, 3, 8, 5, 0, 99, 108, 105, 99, 107, 19, 0, 10, 2, 4, 0, 35, 111, 117, 116, 3, 7, 9, 0, 83, 116, 97, 116, 117, 115, 58, 32, 49, 10 };
    try expectEqualSlices(u8, &expected, bc);
}

test "V2: two bindings, linker patches (unchanged under v0.2)" {
    const bc = try compileWith("on click \"#a\" { set_text \"1\" on \"#a\"; } on input \"#b\" { add_class \"x\" on \"#b\"; }");
    const expected = [_]u8{ 2, 2, 0, 35, 97, 3, 8, 5, 0, 99, 108, 105, 99, 107, 33, 0, 2, 2, 0, 35, 98, 3, 8, 5, 0, 105, 110, 112, 117, 116, 44, 0, 10, 2, 2, 0, 35, 97, 3, 7, 1, 0, 49, 10, 2, 2, 0, 35, 98, 3, 4, 1, 0, 120, 10 };
    try expectEqualSlices(u8, &expected, bc);
}

test "V3 under v0.2: CMP_EQ replaces CMP_STR" {
    const bc = try compileWith("on click \"#go\" { extract_text \"#src\" to v; if v == \"yes\" { set_text \"hit\" on \"#dst\"; } }");
    const expected = [_]u8{ 2, 3, 0, 35, 103, 111, 3, 8, 5, 0, 99, 108, 105, 99, 107, 18, 0, 10, 2, 4, 0, 35, 115, 114, 99, 3, 11, 1, 0, 118, 12, 1, 0, 118, 1, 3, 0, 121, 101, 115, 19, 14, 58, 0, 2, 4, 0, 35, 100, 115, 116, 3, 7, 3, 0, 104, 105, 116, 10 };
    try expectEqualSlices(u8, &expected, bc);
}

test "hover maps to mouseenter" {
    try expectEqualStrings("mouseenter", compiler.eventNameFor("hover"));
    try expectEqualStrings("click", compiler.eventNameFor("click"));
}

test "empty program is just HALT" {
    const bc = try compileWith("");
    try expectEqualSlices(u8, &[_]u8{0x0A}, bc);
}

test "oversized string returns BytecodeTooLarge" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var big: std.ArrayList(u8) = .empty;
    try big.appendSlice(arena.allocator(), "on click \"#b\" { set_text \"");
    try big.appendNTimes(arena.allocator(), 'x', 70000);
    try big.appendSlice(arena.allocator(), "\" on \"#o\"; }");
    try expectError(error.BytecodeTooLarge, compileWith(big.items));
}

test "while loop past 64KiB returns BytecodeTooLarge" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var big: std.ArrayList(u8) = .empty;
    try big.appendSlice(arena.allocator(), "on click \"#b\" { set_text \"");
    try big.appendNTimes(arena.allocator(), 'x', 66000);
    try big.appendSlice(arena.allocator(), "\" on \"#o\"; while n < 3 { inc n; } }");
    try expectError(error.BytecodeTooLarge, compileWith(big.items));
}
