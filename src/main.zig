const std = @import("std");
const markdown = @import("markdown.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const emitter = @import("emitter.zig");

const max_input: usize = 1 << 20;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cairn: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn printDiag(input_path: []const u8, source: []const u8, line_no: u32, col: u32, msg: []const u8) void {
    std.debug.print("error[{s}:{d}:{d}]: {s}\n", .{ input_path, line_no, col, msg });
    var lines = std.mem.splitScalar(u8, source, '\n');
    var i: u32 = 1;
    while (lines.next()) |line| : (i += 1) {
        if (i == line_no) {
            var tmp: [16]u8 = undefined;
            const gutter = std.fmt.bufPrint(&tmp, "  {d} | ", .{line_no}) catch unreachable;
            std.debug.print("{s}{s}\n", .{ gutter, line });
            std.debug.print("{s}", .{gutter});
            var c: u32 = 1;
            while (c < col) : (c += 1) std.debug.print(" ", .{});
            std.debug.print("^\n", .{});
            return;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 or !std.mem.eql(u8, args[1], "build")) {
        std.debug.print("usage: cairn build <input.md>\n", .{});
        std.process.exit(2);
    }
    const input_path = args[2];

    const source = std.Io.Dir.cwd().readFileAlloc(io, input_path, gpa, .limited(max_input)) catch |e| {
        fatal("cannot read {s}: {s}", .{ input_path, @errorName(e) });
    };
    defer gpa.free(source);

    const result = markdown.renderAll(arena, source) catch |e| {
        fatal("markdown error: {s}", .{@errorName(e)});
    };

    var bytecode: []const u8 = &.{0x0A};
    if (result.dsl) |dsl| {
        var diag: ?parser.Diagnostic = null;
        const program = parser.parse(arena, dsl, &diag) catch |e| {
            if (diag) |d| {
                const line_no = result.dsl_line_offset + d.line - 1;
                printDiag(input_path, source, line_no, d.col, d.msg);
            } else {
                std.debug.print("cairn: parse error: {s}\n", .{@errorName(e)});
            }
            std.process.exit(1);
        };
        bytecode = compiler.compile(arena, program) catch |e| {
            fatal("compile error: {s}", .{@errorName(e)});
        };
    }

    const page = emitter.build(arena, .{
        .content = result.html,
        .bytecode = bytecode,
        .title = result.title orelse "Cairn",
    }) catch |e| {
        fatal("emitter error: {s}", .{@errorName(e)});
    };

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "index.html", .data = page.html }) catch |e| {
        fatal("cannot write index.html: {s}", .{@errorName(e)});
    };
    emitter.printReport(page.sizes, "index.html");
}
