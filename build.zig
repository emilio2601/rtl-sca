const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Audio: a small C shim over miniaudio (fetched via build.zig.zon, not vendored).
    // Zig sees only the clean shim API — translate-c on the shim header, never
    // miniaudio.h's nested anonymous structs.
    const miniaudio = b.dependency("miniaudio", .{});
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("c/audio_shim.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate.addIncludePath(b.path("c"));
    root_mod.addImport("audio", translate.createModule());
    root_mod.addIncludePath(b.path("c")); // audio_shim.h
    root_mod.addIncludePath(miniaudio.path(".")); // miniaudio.h from the package cache
    root_mod.addCSourceFile(.{ .file = b.path("c/audio_shim.c"), .flags = &.{} });

    // macOS audio backends miniaudio links against; on Linux it dlopens at runtime.
    if (target.result.os.tag == .macos) {
        root_mod.linkFramework("CoreAudio", .{});
        root_mod.linkFramework("AudioToolbox", .{});
        root_mod.linkFramework("AudioUnit", .{});
        root_mod.linkFramework("CoreFoundation", .{});
    }

    const exe = b.addExecutable(.{ .name = "rtl-sca", .root_module = root_mod });
    b.installArtifact(exe);

    // `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run rtl-sca");
    run_step.dependOn(&run_cmd.step);

    // `zig build test`
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
