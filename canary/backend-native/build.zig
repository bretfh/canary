// canary backend-native shim build.
//
// Produces zig-out/lib/libcanary-native.so: the Zig shim that bridges
// (canary backend-native) on the Scheme side to a glfw + freetype +
// libepoxy native window.  Same shape as guile-webui/build.zig.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Build-time font directory: Guix package definition supplies the
    // store path of font-dejavu's truetype subdir, baked into the .so.
    // Dev fallback ("") makes the runtime look up TTFs by env var or
    // standard system locations only.
    const font_dir = b.option(
        []const u8,
        "font-dir",
        "Directory containing DejaVuSansMono{,-Bold,-Oblique}.ttf; baked into the .so as the default.",
    ) orelse "";

    const opts = b.addOptions();
    opts.addOption([]const u8, "default_font_dir", font_dir);

    const lib = b.addSharedLibrary(.{
        .name = "canary-native",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.root_module.addOptions("build_options", opts);

    // Pull include + link flags for every C library we touch from the
    // guix shell's pkg-config.  Discovers libguile, glfw3, freetype2,
    // and libepoxy whichever guix-current happens to provide.
    add_pkg(b, lib, "guile-3.0");
    add_pkg(b, lib, "glfw3");
    add_pkg(b, lib, "freetype2");
    add_pkg(b, lib, "epoxy");

    // C shims for libguile macros translate-c can't follow.
    lib.addCSourceFile(.{ .file = b.path("wrappers.c"), .flags = &.{} });

    b.installArtifact(lib);
}

fn add_pkg(b: *std.Build, lib: *std.Build.Step.Compile, pkg: []const u8) void {
    const cflags = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--cflags", pkg },
    }) catch |e| std.debug.panic("pkg-config cflags {s}: {}", .{ pkg, e });
    var ci = std.mem.tokenizeAny(u8, cflags.stdout, " \t\r\n");
    while (ci.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            lib.addIncludePath(.{ .cwd_relative = b.allocator.dupe(u8, tok[2..]) catch unreachable });
        }
    }

    const libs = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--libs", pkg },
    }) catch |e| std.debug.panic("pkg-config libs {s}: {}", .{ pkg, e });
    var li = std.mem.tokenizeAny(u8, libs.stdout, " \t\r\n");
    while (li.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-L")) {
            lib.addLibraryPath(.{ .cwd_relative = b.allocator.dupe(u8, tok[2..]) catch unreachable });
        } else if (std.mem.startsWith(u8, tok, "-l")) {
            lib.linkSystemLibrary(b.allocator.dupe(u8, tok[2..]) catch unreachable);
        }
    }
}
