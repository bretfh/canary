const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // ---- user-supplied build flags --------------------------------------
    // canary-build (the Guile CLI) passes these per-project; defaults make
    // a direct `zig build` produce a runnable but useless binary so the
    // wiring is testable without the wrapper.
    const payload_path = b.option([]const u8, "payload",
        "Path to the tar payload to embed in the binary.") orelse "";
    const entry_module = b.option([]const u8, "entry-module",
        "Module name to resolve at startup, e.g. \"my-app main\".") orelse "guile-user";
    const entry_proc = b.option([]const u8, "entry-proc",
        "Procedure within the entry module to call with no args.") orelse "main";
    const out_name = b.option([]const u8, "app-name",
        "Name of the produced binary.") orelse "canary-app";

    const obj_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Wire build_options the runtime needs (entry module + proc names).
    const opts = b.addOptions();
    opts.addOption([]const u8, "entry_module", entry_module);
    opts.addOption([]const u8, "entry_proc", entry_proc);
    obj_mod.addOptions("build_options", opts);

    // Embed the payload.  WriteFile stages both embed.zig (a one-liner)
    // and payload.bin into the same generated directory; @embedFile in
    // embed.zig resolves "payload.bin" relative to embed.zig's source
    // path, which lands at the staged sibling.  -Dpayload absent → an
    // empty payload.bin is staged and main.zig errors out at startup
    // with a clear message.
    const wf = b.addWriteFiles();
    if (payload_path.len > 0) {
        _ = wf.addCopyFile(.{ .cwd_relative = payload_path }, "payload.bin");
    } else {
        _ = wf.add("payload.bin", "");
    }
    const embed_lp = wf.add("embed.zig",
        \\pub const payload: []const u8 = @embedFile("payload.bin");
        \\
    );
    obj_mod.addAnonymousImport("embed.zig", .{
        .root_source_file = embed_lp,
    });

    // Headers — pkg-config --cflags resolves libguile.h.
    const r_cflags = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--cflags", "guile-3.0" },
    }) catch |e| std.debug.panic("pkg-config cflags: {}", .{e});
    var ci = std.mem.tokenizeAny(u8, r_cflags.stdout, " \t\r\n");
    while (ci.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            obj_mod.addIncludePath(.{ .cwd_relative = b.allocator.dupe(u8, tok[2..]) catch unreachable });
        }
    }

    const obj = b.addObject(.{ .name = "canary-app-main", .root_module = obj_mod });

    // Link with gcc — Guile's fat-LTO archives need its linker plugin;
    // LLD can't follow them.  pkg-config --static --libs drives the dep
    // list; `-Wl,-Bstatic` keeps guile deps resolving to .a while system
    // libs (pthread, dl, m, c, rt) stay dynamic.
    const r_libs = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--static", "--libs", "guile-3.0" },
    }) catch |e| std.debug.panic("pkg-config libs: {}", .{e});

    const link = b.addSystemCommand(&.{ "gcc", "-static-libgcc", "-o" });
    const out = link.addOutputFileArg(out_name);
    link.addArtifactArg(obj);

    // fibers-epoll.a from the guix shell env; placed before guile so its
    // symbols (init_fibers_epoll) are pulled in before libguile resolves
    // the extern.
    if (std.posix.getenv("GUIX_ENVIRONMENT")) |env| {
        const fpath = std.fmt.allocPrint(b.allocator,
            "{s}/lib/guile/3.0/extensions/fibers-epoll.a", .{env}) catch unreachable;
        link.addArg(fpath);
    }

    link.addArg("-Wl,-Bstatic");
    var li = std.mem.tokenizeAny(u8, r_libs.stdout, " \t\r\n");
    const sys_libs = [_][]const u8{ "pthread", "dl", "m", "c", "rt" };
    while (li.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-l")) {
            var is_sys = false;
            for (sys_libs) |s| {
                if (std.mem.eql(u8, tok[2..], s)) is_sys = true;
            }
            if (is_sys) {
                link.addArg("-Wl,-Bdynamic");
                link.addArg(b.allocator.dupe(u8, tok) catch unreachable);
                link.addArg("-Wl,-Bstatic");
            } else {
                link.addArg(b.allocator.dupe(u8, tok) catch unreachable);
            }
        } else {
            link.addArg(b.allocator.dupe(u8, tok) catch unreachable);
        }
    }
    link.addArg("-Wl,-Bdynamic");

    const install = b.addInstallBinFile(out, out_name);
    b.getInstallStep().dependOn(&install.step);
}
