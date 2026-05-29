const std = @import("std");
const opts = @import("build_options");
const payload = @import("embed.zig").payload;
const guile = @cImport({
    @cInclude("libguile.h");
    @cInclude("stdlib.h");
});

extern fn init_fibers_epoll() callconv(.c) void;

fn fibers_epoll_init(_: ?*anyopaque) callconv(.c) void {
    init_fibers_epoll();
}

// Static null-terminated copies of the build-time entry strings; the
// libguile C ABI wants `const char *`.
var entry_module_z: [256:0]u8 = undefined;
var entry_proc_z: [256:0]u8 = undefined;

fn inner(_: ?*anyopaque, _: c_int, _: [*c][*c]u8) callconv(.c) void {
    guile.scm_c_register_extension(null, "init_fibers_epoll", fibers_epoll_init, null);

    @memcpy(entry_module_z[0..opts.entry_module.len], opts.entry_module);
    entry_module_z[opts.entry_module.len] = 0;
    @memcpy(entry_proc_z[0..opts.entry_proc.len], opts.entry_proc);
    entry_proc_z[opts.entry_proc.len] = 0;

    const mod = guile.scm_c_resolve_module(&entry_module_z);
    _ = guile.scm_set_current_module(mod);
    const proc_var = guile.scm_c_module_lookup(mod, &entry_proc_z);
    const proc = guile.scm_variable_ref(proc_var);
    _ = guile.scm_call_0(proc);
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    if (payload.len == 0) {
        const msg = "canary-build runtime: built without -Dpayload; refusing to run.\n";
        _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
        std.process.exit(2);
    }

    // 1) sha256(payload)[0..8] → 16 hex chars.  Used as the cache subdir
    //    name so identical builds share a cache and distinct builds get
    //    distinct dirs (so an updated binary doesn't load stale .go).
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex: [16]u8 = std.fmt.bytesToHex(digest[0..8].*, .lower);

    // 2) cache root resolution: XDG_CACHE_HOME, fall back to $HOME/.cache.
    const cache_root = if (std.posix.getenv("XDG_CACHE_HOME")) |x|
        try alloc.dupe(u8, x)
    else
        try std.fmt.allocPrint(alloc, "{s}/.cache", .{std.posix.getenv("HOME") orelse "/tmp"});

    var cache_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&cache_dir_buf, "{s}/canary/{s}", .{ cache_root, hex });

    // 3) Extract payload once.  Skip if the cache dir already exists —
    //    same hash means same content, no need to redo.
    std.fs.cwd().access(cache_dir, .{}) catch {
        try std.fs.cwd().makePath(cache_dir);
        var reader = std.Io.Reader.fixed(payload);
        var dir = try std.fs.cwd().openDir(cache_dir, .{});
        defer dir.close();
        try std.tar.pipeToFileSystem(dir, &reader, .{ .mode_mode = .ignore });
    };

    // 4) Point Guile at the extracted tree.  setenv before scm_boot_guile
    //    so load-path / load-compiled-path see them at boot.
    const lp = try std.fmt.allocPrint(alloc, "{s}/site/3.0\x00", .{cache_dir});
    const lcp = try std.fmt.allocPrint(alloc, "{s}/site-ccache\x00", .{cache_dir});
    _ = guile.setenv("GUILE_LOAD_PATH", @ptrCast(lp.ptr), 1);
    _ = guile.setenv("GUILE_LOAD_COMPILED_PATH", @ptrCast(lcp.ptr), 1);

    // 5) Hand argv to libguile and boot.
    const args = try std.process.argsAlloc(alloc);
    const c_argv = try alloc.alloc([*c]u8, args.len + 1);
    for (args, 0..) |a, i| c_argv[i] = @constCast(@ptrCast(a.ptr));
    c_argv[args.len] = null;
    guile.scm_boot_guile(@intCast(args.len), c_argv.ptr, inner, null);
}
