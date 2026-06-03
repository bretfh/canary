const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const lib = b.addSharedLibrary(.{
        .name = "canary-native",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();

    add_pkg(b, lib, "guile-3.0");
    add_pkg(b, lib, "glfw3");
    add_pkg(b, lib, "freetype2");
    add_pkg(b, lib, "epoxy");

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
