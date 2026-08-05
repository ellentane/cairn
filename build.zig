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

    // stdin -> gzip -> stdout probe for the node cross-inflate test
    // (audio_test.js runs `zig build gzprobe`); build artifact only — not on
    // the default install step, never attached to releases.
    const gzprobe = b.addExecutable(.{
        .name = "gzprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gzprobe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gzprobe.root_module.addImport("audio", b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const gzprobe_step = b.step("gzprobe", "Build the stdin->gzip probe");
    gzprobe_step.dependOn(&b.addInstallArtifact(gzprobe, .{}).step);

    // stdin + profile name -> frame-v2 wav probe (tests/link_profiles_test.js
    // runs `zig build wavprobe`); build artifact only — not on the default
    // install step, never attached to releases.
    const wavprobe = b.addExecutable(.{
        .name = "wavprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wavprobe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wavprobe.root_module.addImport("audio", b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const wavprobe_step = b.step("wavprobe", "Build the stdin+profile->wav probe");
    wavprobe_step.dependOn(&b.addInstallArtifact(wavprobe, .{}).step);

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

    const audio_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audio.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_audio_tests = b.addRunArtifact(audio_tests);
    test_step.dependOn(&run_audio_tests.step);

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
