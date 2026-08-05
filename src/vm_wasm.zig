// Cairn VM in Zig — wasm32-freestanding backend (v1.0).
// Bytecode-identical to src/vm.js. DOM access via 5 JS imports (spec §9.3).
//
// Memory layout (linear memory):
//   0x0000        globals: cur_sel(u32) depth(u32) steps(u32) sp(u32) ret_len(u32)
//   0x0014        context stack: 32 x {ip:u32, sp:u32} = 256 bytes (0x14..0x114)
//   0x1000        bytecode region (8 KiB)
//   0x3000        operand stack: 256 x {ptr:u32, len:u32} = 2 KiB (0x3000..0x37FF)
//   0x3800        state table: 64 x {name[32], ptr:u32, len:u32, cap:u32} =
//                 = 64 x 44 = 2816 B (0x3800..0x4300); name[0] == 0 marks a free
//                 entry; ptr/len/cap point into the state value heap below
//   0x4300        state value heap: 64 KiB, bump + free-list (0x4300..0x14300).
//                 Blocks are {size:u32, payload[...]}; payload starts at block+8.
//                 Free blocks reuse the first 8 bytes as {size:u32, next_free:u32}.
//                 heap_top and free_head are globals that PERSIST across runs
//                 (state lives in the heap); only scratch resets per run.
//   0x14300       scratch region: 64 KiB (per-run, bump-allocated; 0x14300..0x24300).
//                 Sized to the heap so a PUSH_VAR copy of any stored value
//                 fits; only scratch resets per run
//   0x24300       end of memory

const std = @import("std");

// ---- imports (JS glue) ----
extern fn dom_query(ptr: u32, len: u32) u32;
extern fn dom_apply_class(handle: u32, op: u32, ptr: u32, len: u32) void;
extern fn dom_set_text(handle: u32, ptr: u32, len: u32) void;
extern fn dom_get_text(handle: u32, op: u32, dest_ptr: u32, dest_cap: u32) u32;
extern fn dom_on(handle: u32, ptr: u32, len: u32, addr: u32) void;

// ---- memory ----
const MEM_SIZE = 0x24300;
var mem: [MEM_SIZE]u8 = undefined;
const BYTECODE_OFF = 0x1000;
const STACK_OFF = 0x3000;
const STACK_ENTRIES = 256;
const STATE_OFF = 0x3800;
const STATE_ENTRIES = 64;
const NAME_CAP = 32;
const STATE_STRIDE = NAME_CAP + 4 + 4 + 4; // name[32], ptr, len, cap = 44
const HEAP_OFF = 0x4300;
const HEAP_CAP = 0x10000;
const HEAP_END = HEAP_OFF + HEAP_CAP;
const HEAP_MIN = 16;
const SCRATCH_OFF = 0x14300;
const SCRATCH_CAP = 0x10000;
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
var heap_top: u32 = HEAP_OFF;
var free_head: u32 = 0;
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

fn u16At(pos: u32) ?u32 {
    if (pos + 1 >= bytecode_len) return null;
    const p = BYTECODE_OFF + pos;
    return @as(u32, mem[p]) | (@as(u32, mem[p + 1]) << 8);
}

fn strPayload(pos: *u32) ?struct { ptr: u32, len: u32 } {
    const n = u16At(pos.*) orelse return null;
    pos.* += 2;
    if (pos.* + n > bytecode_len) return null;
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
    // mirrors the JS VM's RE_NUM = /^-?\d+(\.\d+)?$/ : a trailing or bare dot
    // ("5.", ".5") is NOT numeric; a leading "-" needs >= 1 digit before any dot
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-') {
        if (s.len == 1) return false;
        i = 1;
    }
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (digits == 0) return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) frac += 1;
        if (frac == 0) return false;
    }
    return i == s.len;
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

// Heap blocks: [size: u32][payload...]; payload starts at block + 8.
// Free blocks reuse the first 8 bytes as [size: u32][next_free: u32].
// Returns the payload pointer and its usable payload capacity (>= max(n, 16)).
fn heapAlloc(n: usize) ?struct { ptr: u32, cap: u32 } {
    const rounded: u32 = @intCast(@max(n, HEAP_MIN));
    var prev: u32 = 0;
    var cur = free_head;
    while (cur != 0) {
        const size = std.mem.readInt(u32, mem[cur..][0..4], .little);
        const next = std.mem.readInt(u32, mem[cur + 4 ..][0..4], .little);
        if (size >= rounded) {
            if (prev == 0) free_head = next else std.mem.writeInt(u32, mem[prev + 4 ..][0..4], next, .little);
            return .{ .ptr = cur + 8, .cap = size };
        }
        prev = cur;
        cur = next;
    }
    if (heap_top + 8 + rounded > HEAP_END) return null;
    const p = heap_top;
    std.mem.writeInt(u32, mem[p..][0..4], rounded, .little);
    heap_top = p + 8 + rounded;
    return .{ .ptr = p + 8, .cap = rounded };
}

fn heapFree(payload_ptr: u32) void {
    if (payload_ptr == 0) return;
    const hdr = payload_ptr - 8;
    const size = std.mem.readInt(u32, mem[hdr..][0..4], .little);
    std.mem.writeInt(u32, mem[hdr..][0..4], size, .little);
    std.mem.writeInt(u32, mem[hdr + 4 ..][0..4], free_head, .little);
    free_head = hdr;
}

fn entryBase(i: u32) u32 {
    return STATE_OFF + i * STATE_STRIDE;
}

fn entryField(e: u32, off: u32) u32 {
    return std.mem.readInt(u32, mem[e + off ..][0..4], .little);
}

fn setEntryField(e: u32, off: u32, v: u32) void {
    std.mem.writeInt(u32, mem[e + off ..][0..4], v, .little);
}

fn stateFind(name: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < STATE_ENTRIES) : (i += 1) {
        const stored = memSlice(entryBase(i), NAME_CAP);
        if (std.mem.indexOfScalar(u8, stored, 0)) |z| {
            if (sliceEq(stored[0..z], name)) return i;
        }
    }
    return null;
}

fn stateLoad(name: []const u8) struct { ptr: u32, len: u32 } {
    if (stateFind(name)) |idx| {
        const e = entryBase(idx);
        return .{ .ptr = entryField(e, NAME_CAP), .len = entryField(e, NAME_CAP + 4) };
    }
    return .{ .ptr = 0, .len = 0 };
}

fn copyEntryName(e: u32, name: []const u8) void {
    const n = @min(name.len, NAME_CAP - 1);
    @memset(memSlice(e, NAME_CAP), 0);
    @memcpy(memSlice(e, n), name[0..n]);
}

fn stateStore(name: []const u8, val: []const u8) bool {
    const idx = stateFind(name) orelse blk: {
        var i: u32 = 0;
        while (i < STATE_ENTRIES) : (i += 1) {
            if (mem[entryBase(i)] == 0) break :blk i;
        }
        return false; // state table full: loud failure
    };
    const e = entryBase(idx);
    var ptr = entryField(e, NAME_CAP);
    const cap = entryField(e, NAME_CAP + 8);
    if (ptr == 0 or cap < val.len) {
        if (ptr != 0) heapFree(ptr);
        const blk = heapAlloc(val.len) orelse {
            setEntryField(e, NAME_CAP, 0);
            setEntryField(e, NAME_CAP + 4, 0);
            setEntryField(e, NAME_CAP + 8, 0);
            return false;
        };
        ptr = blk.ptr;
        setEntryField(e, NAME_CAP, blk.ptr);
        setEntryField(e, NAME_CAP + 8, blk.cap);
    }
    if (val.len > 0) @memcpy(mem[ptr .. ptr + val.len], val);
    setEntryField(e, NAME_CAP + 4, @intCast(val.len));
    copyEntryName(e, name);
    return true;
}

fn getStr() ?[]const u8 {
    const p = strPayload(&ip) orelse return null;
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
                const s = strPayload(&ip) orelse { err = ERR_OPCODE; break; };
                if (!push(s.ptr, s.len)) { err = ERR_OPCODE; break; }
            },
            3 => { // GET_NODES
                const sel = pop();
                cur_sel = dom_query(base() + sel.ptr, sel.len);
            },
            4, 5, 6 => { // ADD/REMOVE/TOGGLE_CLASS
                const cls = strPayload(&ip) orelse { err = ERR_OPCODE; break; };
                dom_apply_class(cur_sel, op - 4, base() + cls.ptr, cls.len);
            },
            7 => { // SET_TEXT
                const t = strPayload(&ip) orelse { err = ERR_OPCODE; break; };
                dom_set_text(cur_sel, base() + t.ptr, t.len);
            },
            8 => { // ON_EVENT
                const ev = strPayload(&ip) orelse { err = ERR_OPCODE; break; };
                const addr = u16At(ip) orelse { err = ERR_OPCODE; break; };
                ip += 2;
                dom_on(cur_sel, base() + ev.ptr, ev.len, addr);
            },
            9 => ip = u16At(ip) orelse { err = ERR_OPCODE; break; }, // JUMP
            10 => break, // HALT
            11, 27 => { // EXTRACT_TEXT / EXTRACT_VALUE
                const name = strPayload(&ip) orelse { err = ERR_OPCODE; break; };
                // extract via scratch (64 KiB, per-run), then copy into an
                // exact-size heap block: doubling heap allocs would fragment
                // the bump pointer (freed intermediates advance heap_top), so
                // a single scratch read keeps the heap contiguous. A read
                // filling the scratch cap is ambiguous truncation -> loud.
                // The scratch buffer is released after the heap copy so
                // subsequent ops (e.g. PUSH_VAR of the value) still have room.
                const saved_extract_scratch = scratch_top;
                const extract_cap = SCRATCH_OFF + SCRATCH_CAP - scratch_top - 8;
                if (extract_cap < 1) { err = ERR_OPCODE; break; }
                const dest = scratchAlloc(extract_cap) orelse { err = ERR_OPCODE; break; };
                const n = dom_get_text(cur_sel, if (op == 11) 0 else 1, base() + dest, extract_cap);
                if (n >= extract_cap) { err = ERR_OPCODE; break; }
                if (!stateStore(memSlice(name.ptr, name.len), memSlice(dest, n))) { err = ERR_OPCODE; break; }
                scratch_top = saved_extract_scratch;
            },
            12 => { // PUSH_VAR (copies the value into scratch so the operand
                // stack never holds heap pointers — stores can free blocks)
                const v = getStr() orelse { err = ERR_OPCODE; break; };
                const st = stateLoad(v);
                if (st.ptr == 0 or st.len == 0) {
                    const p = scratchWrite("") orelse { err = ERR_OPCODE; break; };
                    if (!push(p, 0)) { err = ERR_OPCODE; break; }
                } else {
                    const p = scratchWrite(memSlice(st.ptr, st.len)) orelse { err = ERR_OPCODE; break; };
                    if (!push(p, st.len)) { err = ERR_OPCODE; break; }
                }
            },
            13 => { // CMP_STR
                const b = pop();
                const a = pop();
                const res = sliceEq(memSlice(a.ptr, a.len), memSlice(b.ptr, b.len));
                if (!pushU8(res)) { err = ERR_OPCODE; break; }
            },
            14 => { // JMP_IF_FALSE
                const target = u16At(ip) orelse { err = ERR_OPCODE; break; };
                ip += 2;
                const v = popByte();
                if (v == 0) ip = target;
            },
            15 => { // STORE_VAR
                const v = getStr() orelse { err = ERR_OPCODE; break; };
                const val = pop();
                if (!stateStore(v, memSlice(val.ptr, val.len))) { err = ERR_OPCODE; break; }
            },
            16 => { // INC
                const v = getStr() orelse { err = ERR_OPCODE; break; };
                const cur = stateLoad(v);
                const cur_s = if (cur.ptr == 0) "" else memSlice(cur.ptr, cur.len);
                if (!isNum(cur_s)) { err = ERR_NONNUM; break; }
                const x = std.fmt.parseFloat(f64, cur_s) catch { err = ERR_NONNUM; break; };
                if (!std.math.isFinite(x + 1)) { err = ERR_NONNUM; break; }
                // 400: the longest decimal expansion of any finite f64 is
                // 309 digits + sign; 400 covers all finite values
                var tmp: [400]u8 = undefined;
                const n = fmtFloat(x + 1, &tmp);
                if (!stateStore(v, tmp[0..n])) { err = ERR_OPCODE; break; }
            },
            17 => { // ADD_NUM (JS + semantics)
                const b = pop();
                const a = pop();
                const as = memSlice(a.ptr, a.len);
                const bs = memSlice(b.ptr, b.len);
                if (binNum(as, bs)) |x| {
                    const y = std.fmt.parseFloat(f64, bs) catch 0;
                    if (!std.math.isFinite(x + y)) { err = ERR_NONNUM; break; }
                    var tmp: [400]u8 = undefined;
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
                    if (!std.math.isFinite(x - y)) { err = ERR_NONNUM; break; }
                    var tmp: [400]u8 = undefined;
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
                const target = u16At(ip) orelse { err = ERR_OPCODE; break; };
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
