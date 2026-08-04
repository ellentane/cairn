const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "cairn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const minify = b.addSystemCommand(&.{ "node", "tools/minify_vm.js" });
    const minify_step = b.step("minify", "Regenerate src/vm.min.js from src/vm.js");
    minify_step.dependOn(&minify.step);

    const vm_wasm = b.addExecutable(.{
        .name = "vm_wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm_wasm.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    vm_wasm.entry = .disabled;
    vm_wasm.rdynamic = true;
    b.getInstallStep().dependOn(&b.addInstallArtifact(vm_wasm, .{ .dest_sub_path = "vm_wasm.wasm" }).step);
}
