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

fn usage() noreturn {
    std.debug.print("usage: cairn build <input.md> | cairn fixtures <dir>\n", .{});
    std.process.exit(2);
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

fn buildOne(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, source: []const u8, base: []const u8) !void {
    _ = gpa;
    const result = try markdown.renderAll(arena, source);
    var bytecode: []const u8 = &.{0x0A};
    if (result.dsl) |dsl| {
        var diag: ?parser.Diagnostic = null;
        const program = try parser.parse(arena, dsl, &diag);
        bytecode = try compiler.compile(arena, program);
    }
    const page = try emitter.build(arena, .{
        .content = result.html,
        .bytecode = bytecode,
        .title = result.title orelse "Cairn",
    });

    const bin_path = try std.fmt.allocPrint(arena, "{s}.bin", .{base});
    var bin: std.ArrayList(u8) = .empty;
    defer bin.deinit(arena);
    for (bytecode, 0..) |b, i| {
        if (i > 0) try bin.appendSlice(arena, ", ");
        var tmp: [8]u8 = undefined;
        try bin.appendSlice(arena, std.fmt.bufPrint(&tmp, "{d}", .{b}) catch unreachable);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = bin.items });

    const html_path = try std.fmt.allocPrint(arena, "{s}.html", .{base});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = html_path, .data = page.html });

    const sizes_path = try std.fmt.allocPrint(arena, "{s}.sizes.json", .{base});
    const sizes_json = try std.fmt.allocPrint(arena,
        "{{\"total\":{d},\"shell\":{d},\"content\":{d},\"vm\":{d},\"bytecode\":{d},\"half_life\":{d},\"tier\":\"{s}\"}}",
        .{ page.sizes.total, page.sizes.shell, page.sizes.content, page.sizes.vm, page.sizes.bytecode, emitter.halfLife(page.sizes), emitter.tier(page.sizes.total) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sizes_path, .data = sizes_json });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usage();

    if (std.mem.eql(u8, args[1], "fixtures")) {
        if (args.len < 3) usage();
        const fixtures_dir = args[2];
        var dir = std.Io.Dir.cwd().openDir(io, fixtures_dir, .{ .iterate = true }) catch |e|
            fatal("cannot open {s}: {s}", .{ fixtures_dir, @errorName(e) });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ fixtures_dir, entry.name });
            const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ fixtures_dir, entry.name[0 .. entry.name.len - 3] });
            const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_input)) catch |e| {
                fatal("cannot read {s}: {s}", .{ path, @errorName(e) });
            };
            defer gpa.free(source);
            buildOne(arena, gpa, io, source, base) catch |e| {
                fatal("fixture {s}: {s}", .{ entry.name, @errorName(e) });
            };
        }
        std.debug.print("fixtures regenerated in {s}\n", .{fixtures_dir});
        return;
    }

    if (!std.mem.eql(u8, args[1], "build")) usage();
    if (args.len != 3) usage();
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
