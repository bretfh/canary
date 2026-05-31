const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // ---- user-supplied build flags --------------------------------------
    // canary-build (the Guile CLI) passes these per-project; defaults make
    // a direct `zig build` produce a runnable but useless binary so the
    // wiring is testable without the wrapper.
    const payload_dir = b.option([]const u8, "payload-dir",
        "Directory tree to embed.  Walked recursively; every file becomes one entry in the runtime table addressed by its path relative to this dir.") orelse "";
    const entry_module = b.option([]const u8, "entry-module",
        "Module name to resolve at startup, e.g. \"my-app main\".") orelse "guile-user";
    const entry_proc = b.option([]const u8, "entry-proc",
        "Procedure within the entry module to call with no args.") orelse "main";
    const out_name = b.option([]const u8, "app-name",
        "Name of the produced binary.") orelse "canary-app";
    const backend = b.option([]const u8, "backend",
        "Backend the app uses: 'ansi' (default, minimal) or 'webui' " ++
        "(pulls libwebui-2-static.a + the guile-webui bounce shim).")
        orelse "ansi";
    const guile_webui_src = b.option([]const u8, "guile-webui-src",
        "Path to a guile-webui checkout (provides src/bounce.zig + " ++
        "src/wrappers.c that the webui backend's foreign-thread shim " ++
        "needs).  Required when -Dbackend=webui.")
        orelse "";

    const want_webui = std.mem.eql(u8, backend, "webui");
    if (want_webui and guile_webui_src.len == 0) {
        std.debug.panic("-Dbackend=webui requires -Dguile-webui-src=PATH", .{});
    }

    const obj_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Wire build_options the runtime needs (entry module + proc names,
    // backend selector so main.zig knows whether to call
    // init_guile_webui_bounce before user Scheme).
    const opts = b.addOptions();
    opts.addOption([]const u8, "entry_module", entry_module);
    opts.addOption([]const u8, "entry_proc", entry_proc);
    opts.addOption(bool, "want_webui", want_webui);
    obj_mod.addOptions("build_options", opts);

    // Walk -Dpayload-dir at BUILD TIME, stage every file into a WriteFile
    // tree, and generate an embed.zig that holds a `path → bytes` table
    // built from one `@embedFile` per file.  No tar, no runtime extract,
    // no cache dir — the runtime reads from the embedded bytes directly
    // via a try-module-autoload override.
    const wf = b.addWriteFiles();
    var entries_buf = std.ArrayList(u8){};
    defer entries_buf.deinit(b.allocator);

    if (payload_dir.len > 0) {
        var dir = std.fs.cwd().openDir(payload_dir, .{ .iterate = true }) catch |e|
            std.debug.panic("payload-dir {s}: {}", .{ payload_dir, e });
        defer dir.close();
        var walker = dir.walk(b.allocator) catch unreachable;
        defer walker.deinit();
        while ((walker.next() catch unreachable)) |entry| {
            if (entry.kind != .file) continue;
            const rel = b.allocator.dupe(u8, entry.path) catch unreachable;
            const abs = std.fs.path.join(b.allocator, &.{ payload_dir, rel }) catch unreachable;
            _ = wf.addCopyFile(.{ .cwd_relative = abs }, rel);
            (entries_buf.writer(b.allocator).print(
                "    .{{ .path = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n",
                .{ rel, rel },
            ) catch unreachable);
        }
    }

    const embed_content = std.fmt.allocPrint(b.allocator,
        \\pub const Entry = struct {{ path: []const u8, bytes: []const u8 }};
        \\pub const entries: []const Entry = &.{{
        \\{s}
        \\}};
        \\
    , .{entries_buf.items}) catch unreachable;
    const embed_lp = wf.add("embed.zig", embed_content);
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
    //
    // -rdynamic exports linked-in static-library symbols into the
    // executable's dynamic symbol table so (dynamic-link)+(dynamic-func)
    // from Scheme can resolve them at runtime.  Required for the webui
    // backend (webui.scm does dynamic-link "webui-2" then dynamic-func
    // for every C call); harmless for ansi-only binaries.
    const r_libs = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--static", "--libs", "guile-3.0" },
    }) catch |e| std.debug.panic("pkg-config libs: {}", .{e});

    // Drop -static-libgcc: with pthread-spawning code (the webui
    // backend's CIVETweb workers, eventually any backend that uses
    // libpthread internally), glibc's pthread_exit still tries to
    // dlopen libgcc_s.so.1 at thread teardown to walk the unwind
    // tables.  If libgcc_s.so.1 isn't accessible we abort with
    // "libgcc_s.so.1 must be installed for pthread_exit to work".
    // Linking libgcc dynamically adds it to NEEDED — every Linux
    // system ships it — and keeps pthread cleanup paths working.
    const link = b.addSystemCommand(&.{ "gcc", "-rdynamic", "-o" });
    const out = link.addOutputFileArg(out_name);
    link.addArtifactArg(obj);

    // C shims for the libguile macros that translate-c can't follow.
    const wrappers_o = b.addSystemCommand(&.{ "gcc", "-c", "-fPIE", "-o" });
    const wrappers_lp = wrappers_o.addOutputFileArg("wrappers.o");
    var ci_w = std.mem.tokenizeAny(u8, r_cflags.stdout, " \t\r\n");
    while (ci_w.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            wrappers_o.addArg(b.allocator.dupe(u8, tok) catch unreachable);
        }
    }
    wrappers_o.addFileArg(b.path("src/wrappers.c"));
    link.addFileArg(wrappers_lp);

    // Webui backend: compile the bounce shim straight out of a
    // guile-webui checkout (src/bounce.zig + src/wrappers.c) and link
    // it as an additional object, plus whole-archive libwebui-2-static.a
    // from the guix shell's profile.  No -static-lib middleman: the
    // shim is two files, building it directly keeps the L3 path the
    // same shape as the existing fibers-epoll wiring.
    if (want_webui) {
        const bounce_mod = b.createModule(.{
            .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ guile_webui_src, "src/bounce.zig" }) },
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        var ci_b = std.mem.tokenizeAny(u8, r_cflags.stdout, " \t\r\n");
        while (ci_b.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-I")) {
                bounce_mod.addIncludePath(.{ .cwd_relative = b.allocator.dupe(u8, tok[2..]) catch unreachable });
            }
        }
        const bounce_obj = b.addObject(.{ .name = "guile-webui-bounce", .root_module = bounce_mod });
        link.addArtifactArg(bounce_obj);

        // bounce.zig's wrappers (SCM_UNDEFINED / SCM_UNBNDP shims).
        const bounce_wrap_o = b.addSystemCommand(&.{ "gcc", "-c", "-fPIE", "-o" });
        const bounce_wrap_lp = bounce_wrap_o.addOutputFileArg("guile-webui-wrappers.o");
        var ci_bw = std.mem.tokenizeAny(u8, r_cflags.stdout, " \t\r\n");
        while (ci_bw.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-I")) {
                bounce_wrap_o.addArg(b.allocator.dupe(u8, tok) catch unreachable);
            }
        }
        bounce_wrap_o.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ guile_webui_src, "src/wrappers.c" }) });
        link.addFileArg(bounce_wrap_lp);

        // libwebui-2-static.a is in the same profile lib dir as the
        // other static deps (the canary deps webui package installs it
        // alongside the .so).  Whole-archive so every exported symbol
        // is retained even though the producing app only calls a
        // subset via dynamic-link "webui-2"; otherwise dlsym at
        // runtime can't see them.
        if (std.posix.getenv("GUIX_ENVIRONMENT")) |env| {
            const wpath = std.fmt.allocPrint(b.allocator,
                "{s}/lib/libwebui-2-static.a", .{env}) catch unreachable;
            link.addArg("-Wl,--whole-archive");
            link.addArg(wpath);
            link.addArg("-Wl,--no-whole-archive");
        }
    }

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
