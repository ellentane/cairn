// Cairn VM in Zig — wasm32-freestanding backend (v1.0).
// Bytecode-identical to src/vm.js. DOM access via 5 JS imports (spec §9.3).
//
// Memory layout (linear memory):
//   0x0000        globals: cur_sel(u32) depth(u32) steps(u32) sp(u32) ret_len(u32)
//   0x0014        context stack: 32 x {ip:u32, sp:u32} = 256 bytes (0x14..0x114)
//   0x1000        bytecode region (8 KiB)
//   0x3000        operand stack: 256 x {ptr:u32, len:u32} = 2 KiB (0x3000..0x37FF)
//   0x3800        state table: 64 x {name[32], val[32]} = 4 KiB (0x3800..0x47FF)
//   0x4800        scratch region (2 KiB, bump-allocated per run)
//   0x5000        end of memory

const std = @import("std");

// ---- imports (JS glue) ----
extern fn dom_query(ptr: u32, len: u32) u32;
extern fn dom_apply_class(handle: u32, op: u32, ptr: u32, len: u32) void;
extern fn dom_set_text(handle: u32, ptr: u32, len: u32) void;
extern fn dom_get_text(handle: u32, op: u32, dest_ptr: u32, dest_cap: u32) u32;
extern fn dom_on(handle: u32, ptr: u32, len: u32, addr: u32) void;

// ---- memory ----
const MEM_SIZE = 0x5000;
var mem: [MEM_SIZE]u8 = undefined;
const BYTECODE_OFF = 0x1000;
const STACK_OFF = 0x3000;
const STACK_ENTRIES = 256;
const STATE_OFF = 0x3800;
const STATE_ENTRIES = 64;
const NAME_CAP = 32;
const VAL_CAP = 32;
const SCRATCH_OFF = 0x4800;
const SCRATCH_CAP = 0x800;
const MAX_DEPTH = 32;
const MAX_STEPS = 1000000;

const ERR_OK: u32 = 0;
const ERR_STEP: u32 = 1;
const ERR_DEPTH: u32 = 2;
const ERR_OPCODE: u32 = 3;
const ERR_NONNUM: u32 = 4;

var cur_sel: u32 = 0;
var depth: u32 = 0;
var steps: u32 = 0;
var sp: u32 = 0;
var scratch_top: u32 = SCRATCH_OFF;
var ip: u32 = 0;
var bytecode_len: u32 = 0;

export fn mem_base() u32 {
    return @intFromPtr(&mem);
}

fn memSlice(off: u32, len: u32) []u8 {
    return mem[off .. off + len];
}

fn base() u32 {
    return @intFromPtr(&mem);
}

fn u16At(pos: u32) u32 {
    const p = BYTECODE_OFF + pos;
    return @as(u32, mem[p]) | (@as(u32, mem[p + 1]) << 8);
}

fn strPayload(pos: *u32) struct { ptr: u32, len: u32 } {
    const n = u16At(pos.*);
    pos.* += 2;
    const rel = pos.*;
    pos.* += n;
    return .{ .ptr = BYTECODE_OFF + rel, .len = n };
}

fn push(ptr: u32, len: u32) bool {
    if (sp >= STACK_ENTRIES) return false;
    const b_ = STACK_OFF + sp * 8;
    mem[b_..][0..4].* = @bitCast(ptr);
    mem[b_ + 4 ..][0..4].* = @bitCast(len);
    sp += 1;
    return true;
}

fn pop() struct { ptr: u32, len: u32 } {
    if (sp == 0) return .{ .ptr = 0, .len = 0 };
    sp -= 1;
    const b_ = STACK_OFF + sp * 8;
    const ptr: u32 = @bitCast(mem[b_..][0..4].*);
    const len: u32 = @bitCast(mem[b_ + 4 ..][0..4].*);
    return .{ .ptr = ptr, .len = len };
}

fn sliceEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isNum(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-') {
        if (s.len == 1) return false;
        i = 1;
    }
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    }
    return digits > 0 and i == s.len;
}

fn fmtFloat(x: f64, out: []u8) usize {
    if (x == 0 and std.math.signbit(x)) {
        out[0] = '0';
        return 1;
    }
    const s = std.fmt.bufPrint(out, "{d}", .{x}) catch return 0;
    return s.len;
}

fn scratchAlloc(n: usize) ?u32 {
    if (scratch_top + n > SCRATCH_OFF + SCRATCH_CAP) return null;
    const p = scratch_top;
    scratch_top += @intCast(n);
    return p;
}

fn scratchWrite(s: []const u8) ?u32 {
    const p = scratchAlloc(s.len) orelse return null;
    @memcpy(mem[p .. p + s.len], s);
    return p;
}

fn stateFind(name: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < STATE_ENTRIES) : (i += 1) {
        const b_ = STATE_OFF + i * (NAME_CAP + VAL_CAP);
        const stored = memSlice(b_, NAME_CAP);
        if (std.mem.indexOfScalar(u8, stored, 0)) |z| {
            if (sliceEq(stored[0..z], name)) return i;
        }
    }
    return null;
}

fn stateStore(name: []const u8, val: []const u8) void {
    const idx = stateFind(name) orelse blk: {
        var i: u32 = 0;
        while (i < STATE_ENTRIES) : (i += 1) {
            const b_ = STATE_OFF + i * (NAME_CAP + VAL_CAP);
            if (mem[b_] == 0) break :blk i;
        }
        return; // state full: drop silently (documented limit)
    };
    const b_ = STATE_OFF + idx * (NAME_CAP + VAL_CAP);
    @memset(memSlice(b_, NAME_CAP + VAL_CAP), 0);
    const n = @min(name.len, NAME_CAP - 1);
    @memcpy(memSlice(b_, n), name[0..n]);
    const v = @min(val.len, VAL_CAP - 1);
    @memcpy(memSlice(b_ + NAME_CAP, v), val[0..v]);
}

fn stateLoad(name: []const u8) []const u8 {
    if (stateFind(name)) |idx| {
        const b_ = STATE_OFF + idx * (NAME_CAP + VAL_CAP);
        const stored = memSlice(b_ + NAME_CAP, VAL_CAP);
        if (std.mem.indexOfScalar(u8, stored, 0)) |z| return stored[0..z];
        return stored;
    }
    return "";
}

fn getStr() []const u8 {
    const p = strPayload(&ip);
    return memSlice(p.ptr, p.len);
}

fn binNum(a: []const u8, b: []const u8) ?f64 {
    if (!isNum(a) or !isNum(b)) return null;
    return std.fmt.parseFloat(f64, a) catch return null;
}

fn run(entry: u32) u32 {
    if (depth >= MAX_DEPTH) return ERR_DEPTH;
    depth += 1;
    const saved_ip = ip;
    const saved_sp = sp;
    const saved_scratch = scratch_top;
    ip = entry;
    sp = 0;
    scratch_top = SCRATCH_OFF;
    const base_steps = steps;
    steps = 0;
    var err: u32 = ERR_OK;

    while (ip < bytecode_len) {
        if (steps >= MAX_STEPS) {
            err = ERR_STEP;
            break;
        }
        steps += 1;
        const op = mem[BYTECODE_OFF + ip];
        ip += 1;
        switch (op) {
            1, 2 => { // PUSH_STR / PUSH_SELECTOR
                const s = strPayload(&ip);
                if (!push(s.ptr, s.len)) { err = ERR_OPCODE; break; }
            },
            3 => { // GET_NODES
                const sel = pop();
                cur_sel = dom_query(base() + sel.ptr, sel.len);
            },
            4, 5, 6 => { // ADD/REMOVE/TOGGLE_CLASS
                const cls = strPayload(&ip);
                dom_apply_class(cur_sel, op - 4, base() + cls.ptr, cls.len);
            },
            7 => { // SET_TEXT
                const t = strPayload(&ip);
                dom_set_text(cur_sel, base() + t.ptr, t.len);
            },
            8 => { // ON_EVENT
                const ev = strPayload(&ip);
                const addr = u16At(ip);
                ip += 2;
                dom_on(cur_sel, base() + ev.ptr, ev.len, addr);
            },
            9 => ip = u16At(ip), // JUMP
            10 => break, // HALT
            11, 27 => { // EXTRACT_TEXT / EXTRACT_VALUE
                const name = strPayload(&ip);
                const cap = VAL_CAP - 1;
                const dest = scratchAlloc(cap) orelse { err = ERR_OPCODE; break; };
                const n = dom_get_text(cur_sel, if (op == 11) 0 else 1, base() + dest, cap);
                stateStore(memSlice(name.ptr, name.len), memSlice(dest, n));
            },
            12 => { // PUSH_VAR
                const v = getStr();
                if (stateFind(v)) |idx| {
                    const b_ = STATE_OFF + idx * (NAME_CAP + VAL_CAP);
                    const stored = memSlice(b_ + NAME_CAP, VAL_CAP);
                    const vlen = if (std.mem.indexOfScalar(u8, stored, 0)) |z| z else stored.len;
                    if (!push(b_ + NAME_CAP, @intCast(vlen))) { err = ERR_OPCODE; break; }
                } else {
                    const p = scratchWrite("") orelse { err = ERR_OPCODE; break; };
                    if (!push(p, 0)) { err = ERR_OPCODE; break; }
                }
            },
            13 => { // CMP_STR
                const b = pop();
                const a = pop();
                const res = sliceEq(memSlice(a.ptr, a.len), memSlice(b.ptr, b.len));
                if (!pushU8(res)) { err = ERR_OPCODE; break; }
            },
            14 => { // JMP_IF_FALSE
                const target = u16At(ip);
                ip += 2;
                const v = popByte();
                if (v == 0) ip = target;
            },
            15 => { // STORE_VAR
                const v = getStr();
                const val = pop();
                stateStore(v, memSlice(val.ptr, val.len));
            },
            16 => { // INC
                const v = getStr();
                const cur = stateLoad(v);
                if (!isNum(cur)) { err = ERR_NONNUM; break; }
                const x = std.fmt.parseFloat(f64, cur) catch { err = ERR_NONNUM; break; };
                var tmp: [64]u8 = undefined;
                const n = fmtFloat(x + 1, &tmp);
                stateStore(v, tmp[0..n]);
            },
            17 => { // ADD_NUM (JS + semantics)
                const b = pop();
                const a = pop();
                const as = memSlice(a.ptr, a.len);
                const bs = memSlice(b.ptr, b.len);
                if (binNum(as, bs)) |x| {
                    const y = std.fmt.parseFloat(f64, bs) catch 0;
                    var tmp: [64]u8 = undefined;
                    const n = fmtFloat(x + y, &tmp);
                    const p = scratchWrite(tmp[0..n]) orelse { err = ERR_OPCODE; break; };
                    if (!push(p, n)) { err = ERR_OPCODE; break; }
                } else {
                    const p = scratchWrite(as) orelse { err = ERR_OPCODE; break; };
                    _ = scratchWrite(bs) orelse { err = ERR_OPCODE; break; };
                    if (!push(p, as.len + bs.len)) { err = ERR_OPCODE; break; }
                }
            },
            18 => { // SUB_NUM
                const b = pop();
                const a = pop();
                if (binNum(memSlice(a.ptr, a.len), memSlice(b.ptr, b.len))) |x| {
                    const y = std.fmt.parseFloat(f64, memSlice(b.ptr, b.len)) catch 0;
                    var tmp: [64]u8 = undefined;
                    const n = fmtFloat(x - y, &tmp);
                    const p = scratchWrite(tmp[0..n]) orelse { err = ERR_OPCODE; break; };
                    if (!push(p, n)) { err = ERR_OPCODE; break; }
                } else { err = ERR_NONNUM; break; }
            },
            19...24 => { // CMP family
                const b = pop();
                const a = pop();
                const as = memSlice(a.ptr, a.len);
                const bs = memSlice(b.ptr, b.len);
                var res = false;
                if (binNum(as, bs)) |x| {
                    const y = std.fmt.parseFloat(f64, bs) catch 0;
                    res = switch (op) {
                        19 => x == y, 20 => x != y, 21 => x < y,
                        22 => x > y, 23 => x <= y, 24 => x >= y,
                        else => unreachable,
                    };
                } else {
                    res = switch (op) {
                        19 => sliceEq(as, bs),
                        20 => !sliceEq(as, bs),
                        21 => std.mem.lessThan(u8, as, bs),
                        22 => std.mem.lessThan(u8, bs, as),
                        23 => std.mem.lessThan(u8, as, bs) or sliceEq(as, bs),
                        24 => std.mem.lessThan(u8, bs, as) or sliceEq(as, bs),
                        else => unreachable,
                    };
                }
                if (!pushU8(res)) { err = ERR_OPCODE; break; }
            },
            25 => { // JMP_IF_TRUE
                const target = u16At(ip);
                ip += 2;
                if (popByte() != 0) ip = target;
            },
            26 => { // SET_TEXT_POP
                const val = pop();
                dom_set_text(cur_sel, base() + val.ptr, val.len);
            },
            else => { err = ERR_OPCODE; break; },
        }
    }

    steps = base_steps;
    scratch_top = saved_scratch;
    sp = saved_sp;
    ip = saved_ip;
    depth -= 1;
    return err;
}

fn pushU8(v: bool) bool {
    const p = scratchAlloc(1) orelse return false;
    mem[p] = if (v) 1 else 0;
    return push(p, 1);
}

fn popByte() u8 {
    const v = pop();
    return if (v.len > 0) mem[v.ptr] else 0;
}

export fn run_main(len: u32) u32 {
    bytecode_len = len;
    ip = 0;
    sp = 0;
    depth = 0;
    cur_sel = 0;
    return run(0);
}

export fn run_at(addr: u32) u32 {
    return run(addr);
}

/// §9.3 handler argument passing: the glue sets the current-selection slot to
/// the captured handle before run_at, mirroring the JS VM's handler-stack push.
export fn set_cur_sel(handle: u32) void {
    cur_sel = handle;
}
