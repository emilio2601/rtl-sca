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

    // Single source of truth for the version: build.zig.zon, exposed to the code
    // as `@import("build_options").version` (for `--version`).
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    root_mod.addOptions("build_options", build_options);

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

    // librtlsdr (USB IQ source). Clean C API → translate-c directly on the header,
    // no shim. On Linux/Pi the lib lives on the default search path; on macOS it's
    // under the Homebrew prefix, which is not searched by default.
    const rtlsdr = b.addTranslateC(.{
        .root_source_file = b.path("c/rtlsdr.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rtlsdr.addIncludePath(b.path("c"));
    switch (target.result.os.tag) {
        .macos => {
            // Homebrew's prefix isn't on the default search path and differs by
            // arch; ask brew where librtlsdr lives. Skip quietly if brew/the
            // formula is absent — the link step then reports "library not found".
            var code: u8 = undefined;
            if (b.runAllowFail(&.{ "brew", "--prefix", "librtlsdr" }, &code, .ignore)) |out| {
                const prefix = std.mem.trim(u8, out, " \t\r\n");
                const inc = b.pathJoin(&.{ prefix, "include" });
                rtlsdr.addIncludePath(.{ .cwd_relative = inc });
                root_mod.addIncludePath(.{ .cwd_relative = inc });
                root_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
            } else |_| {}
        },
        else => {
            // librtlsdr built from source (e.g. on Raspberry Pi OS) lands in
            // /usr/local, which isn't always on the default search path.
            rtlsdr.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
            root_mod.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
            root_mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
        },
    }
    root_mod.addImport("rtlsdr", rtlsdr.createModule());
    root_mod.linkSystemLibrary("rtlsdr", .{});

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
