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
};

pub fn eventNameFor(evt: []const u8) []const u8 {
    return if (std.mem.eql(u8, evt, "hover")) "mouseenter" else evt;
}

fn appendStr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
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

fn emitDomAction(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), dom: parser.DomOp) !void {
    try buf.append(allocator, op.PUSH_SELECTOR);
    try appendStr(allocator, buf, dom.selector);
    try buf.append(allocator, op.GET_NODES);
    try buf.append(allocator, domOpcode(dom.kind));
    try appendStr(allocator, buf, dom.class);
}

fn emitAction(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), action: parser.Action) !void {
    switch (action) {
        .dom => |dom| try emitDomAction(allocator, buf, dom),
        .extract => |ex| {
            try buf.append(allocator, op.PUSH_SELECTOR);
            try appendStr(allocator, buf, ex.selector);
            try buf.append(allocator, op.GET_NODES);
            try buf.append(allocator, op.EXTRACT_TEXT);
            try appendStr(allocator, buf, ex.var_name);
        },
        .if_stmt => |s| {
            try buf.append(allocator, op.PUSH_VAR);
            try appendStr(allocator, buf, s.var_name);
            try buf.append(allocator, op.PUSH_STR);
            try appendStr(allocator, buf, s.value);
            try buf.append(allocator, op.CMP_STR);
            try buf.append(allocator, op.JMP_IF_FALSE);
            const slot = buf.items.len; // backpatch: target = end of body
            try buf.appendSlice(allocator, &.{ 0, 0 });
            for (s.body) |a| try emitAction(allocator, buf, a);
            const target: u16 = @intCast(buf.items.len);
            buf.items[slot] = @truncate(target);
            buf.items[slot + 1] = @truncate(target >> 8);
        },
    }
}

pub fn compile(allocator: std.mem.Allocator, prog: parser.Program) CompileError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var addr_slots: std.ArrayList(usize) = .empty;
    errdefer addr_slots.deinit(allocator);
    var block_starts: std.ArrayList(usize) = .empty;
    errdefer block_starts.deinit(allocator);

    for (prog.bindings) |b| {
        try buf.append(allocator, op.PUSH_SELECTOR);
        try appendStr(allocator, &buf, b.selector);
        try buf.append(allocator, op.GET_NODES);
        try buf.append(allocator, op.ON_EVENT);
        try appendStr(allocator, &buf, eventNameFor(b.event));
        const slot = buf.items.len;
        try buf.appendSlice(allocator, &.{ 0, 0 }); // patched by linker pass
        try addr_slots.append(allocator, slot);
    }
    try buf.append(allocator, op.HALT);

    for (prog.bindings) |b| {
        try block_starts.append(allocator, buf.items.len);
        for (b.body) |a| try emitAction(allocator, &buf, a);
        try buf.append(allocator, op.HALT); // trailing block terminator: handlers must not run into the next block
    }

    for (addr_slots.items, 0..) |slot, idx| {
        const addr: u16 = @intCast(block_starts.items[idx]);
        buf.items[slot] = @truncate(addr);
        buf.items[slot + 1] = @truncate(addr >> 8);
    }
    if (buf.items.len > 0xFFFF) return error.BytecodeTooLarge;
    return buf.toOwnedSlice(allocator);
}

const compiler = @import("compiler.zig");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;

fn compileWith(src: []const u8) ![]u8 {
    // arena intentionally leaked (page_allocator); deinit would free the bytecode
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var diag: ?parser.Diagnostic = null;
    const prog = try parser.parse(arena.allocator(), src, &diag);
    return compiler.compile(arena.allocator(), prog);
}

test "V1: single set_text binding" {
    const bc = try compileWith("on click \"#btn\" { set_text \"Status: 1\" on \"#out\"; }");
    const expected = [_]u8{ 2, 4, 0, 35, 98, 116, 110, 3, 8, 5, 0, 99, 108, 105, 99, 107, 19, 0, 10, 2, 4, 0, 35, 111, 117, 116, 3, 7, 9, 0, 83, 116, 97, 116, 117, 115, 58, 32, 49, 10 };
    try expectEqualSlices(u8, &expected, bc);
}

test "V2: two bindings, linker patches addresses, trailing HALTs" {
    const bc = try compileWith("on click \"#a\" { set_text \"1\" on \"#a\"; } on input \"#b\" { add_class \"x\" on \"#b\"; }");
    const expected = [_]u8{ 2, 2, 0, 35, 97, 3, 8, 5, 0, 99, 108, 105, 99, 107, 33, 0, 2, 2, 0, 35, 98, 3, 8, 5, 0, 105, 110, 112, 117, 116, 44, 0, 10, 2, 2, 0, 35, 97, 3, 7, 1, 0, 49, 10, 2, 2, 0, 35, 98, 3, 4, 1, 0, 120, 10 };
    try expectEqualSlices(u8, &expected, bc);
}

test "V3: extract_text and if with backpatched jump to trailing HALT" {
    const bc = try compileWith("on click \"#go\" { extract_text \"#src\" to v; if v == \"yes\" { set_text \"hit\" on \"#dst\"; } }");
    const expected = [_]u8{ 2, 3, 0, 35, 103, 111, 3, 8, 5, 0, 99, 108, 105, 99, 107, 18, 0, 10, 2, 4, 0, 35, 115, 114, 99, 3, 11, 1, 0, 118, 12, 1, 0, 118, 1, 3, 0, 121, 101, 115, 13, 14, 58, 0, 2, 4, 0, 35, 100, 115, 116, 3, 7, 3, 0, 104, 105, 116, 10 };
    try expectEqualSlices(u8, &expected, bc);
}

test "hover maps to mouseenter" {
    try expectEqualStrings("mouseenter", compiler.eventNameFor("hover"));
    try expectEqualStrings("click", compiler.eventNameFor("click"));
    try expectEqualStrings("input", compiler.eventNameFor("input"));
    try expectEqualStrings("load", compiler.eventNameFor("load"));
}

test "empty program is just HALT" {
    const bc = try compileWith("");
    try expectEqualSlices(u8, &[_]u8{0x0A}, bc);
}
