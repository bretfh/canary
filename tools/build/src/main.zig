const std = @import("std");
const opts = @import("build_options");
const embed = @import("embed.zig");
const guile = @cImport({
    @cInclude("libguile.h");
});

extern fn init_fibers_epoll() callconv(.c) void;
extern fn canary_scm_false() guile.SCM;
extern fn canary_scm_make_bv(len: usize) guile.SCM;
extern fn canary_scm_bv_write(bv: guile.SCM, src: [*]const u8, len: usize) void;

fn fibers_epoll_init(_: ?*anyopaque) callconv(.c) void {
    init_fibers_epoll();
}

// Foreign procedure exposed as `%canary-find` in Guile.  Takes a path
// string, returns a bytevector wrapping the embedded bytes if found,
// else #f.  The Scheme override calls this for every module the engine
// tries to autoload.
fn canary_find(path_scm: guile.SCM) callconv(.c) guile.SCM {
    const cstr_z = guile.scm_to_utf8_string(path_scm);
    if (cstr_z == null) return canary_scm_false();
    const cstr = std.mem.span(@as([*c]const u8, cstr_z));
    var found: ?[]const u8 = null;
    for (embed.entries) |e| {
        if (std.mem.eql(u8, e.path, cstr)) {
            found = e.bytes;
            break;
        }
    }
    guile.free(cstr_z);

    if (found) |bytes| {
        const bv = canary_scm_make_bv(bytes.len);
        canary_scm_bv_write(bv, bytes.ptr, bytes.len);
        return bv;
    }
    return canary_scm_false();
}

// Scheme glue: registers %canary-find from C and overrides
// try-module-autoload in (guile) so module lookup checks the embed table
// before falling through to the normal load path.  .go bytes go through
// load-thunk-from-memory; .scm bytes are read+evaluated form by form
// into a fresh module that try-module-autoload itself set up.
const override_glue =
    \\(use-modules (system vm loader)
    \\             (rnrs bytevectors)
    \\             (ice-9 binary-ports))
    \\
    \\(define %orig (@ (guile) try-module-autoload))
    \\
    \\(define (%load-scm-bytes bv)
    \\  (let ((port (open-bytevector-input-port bv)))
    \\    (set-port-encoding! port "UTF-8")
    \\    (let loop ()
    \\      (let ((form (read port)))
    \\        (unless (eof-object? form)
    \\          (primitive-eval form)
    \\          (loop))))))
    \\
    \\(define (%load-go-bytes bv)
    \\  ;; Bundled .go may be incompatible with the runtime guile's
    \\  ;; bytecode version.  On any error fall through to the .scm copy.
    \\  (false-if-exception ((load-thunk-from-memory bv))))
    \\
    \\(define (%try-embed module-name . rest)
    \\  (let* ((parts (map symbol->string module-name))
    \\         (base  (string-join parts "/"))
    \\         (go    (string-append "site-ccache/" base ".go"))
    \\         (scm   (string-append "site/3.0/" base ".scm"))
    \\         (go-bv (%canary-find go)))
    \\    (cond
    \\     ((and go-bv (%load-go-bytes go-bv)) #t)
    \\     ((%canary-find scm)
    \\      => (lambda (bv) (%load-scm-bytes bv) #t))
    \\     (else (apply %orig module-name rest)))))
    \\
    \\(module-define! (resolve-module '(guile)) 'try-module-autoload %try-embed)
    \\
;

// Buffers for the null-terminated copies of build-time entry strings.
var entry_module_z: [256:0]u8 = undefined;
var entry_proc_z: [256:0]u8 = undefined;

fn inner(_: ?*anyopaque, _: c_int, _: [*c][*c]u8) callconv(.c) void {
    guile.scm_c_register_extension(null, "init_fibers_epoll", fibers_epoll_init, null);

    // Expose %canary-find then install the autoload override.
    _ = guile.scm_c_define_gsubr("%canary-find", 1, 0, 0, @constCast(@ptrCast(&canary_find)));
    _ = guile.scm_c_eval_string(override_glue.ptr);

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

    if (embed.entries.len == 0) {
        const msg = "canary-build runtime: built without -Dpayload-dir; refusing to run.\n";
        _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
        std.process.exit(2);
    }

    const args = try std.process.argsAlloc(alloc);
    const c_argv = try alloc.alloc([*c]u8, args.len + 1);
    for (args, 0..) |a, i| c_argv[i] = @constCast(@ptrCast(a.ptr));
    c_argv[args.len] = null;
    guile.scm_boot_guile(@intCast(args.len), c_argv.ptr, inner, null);
}
