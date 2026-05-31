# Shipping gcell apps as static binaries

This is the half of gcell's story that isn't `guile -L gcell
myapp.scm`. It covers how a gcell app — your widget tree, your
modules, the gcell library itself, libguile, and guile-fibers — becomes
a single Linux binary that runs anywhere without a Guile install. The
machinery lives at `tools/build/`; this doc covers the model.

## When you'd reach for this

- You wrote a gcell app for yourself and now want to give it to someone
  else without making them install Guile first.
- You want a single-file artifact: download, `chmod +x`, run. No
  package manager, no setup script, no language runtime to bring
  along.
- You want the artifact to leave no traces — no cache dir, no XDG
  paths, no auto-compile cruft growing in the user's home.

If you're just iterating on your own machine, ignore this whole doc.
`guile -L gcell myapp.scm` is faster to start, lets you `C-c C-c`
into running code from emacs, and skips the entire static-build
pipeline.

## The artifact

```
$ gcell-build ship
+ ... staging ...
+ ... zig build -Dpayload-dir=... ...
built dist/my-app

$ file dist/my-app
dist/my-app: ELF 64-bit LSB executable, x86-64, statically linked-ish

$ ls -lah dist/my-app
-rwxr-xr-x  1 you  you  19M  dist/my-app

$ objdump -p dist/my-app | grep NEEDED
NEEDED  libm.so.6
NEEDED  libc.so.6
NEEDED  ld-linux-x86-64.so.2

$ ./dist/my-app
[your app runs]

$ ls ~/.cache/gcell
ls: cannot access '/home/you/.cache/gcell': No such file or directory
```

That's the shape. ~15-20 MB depending on app size, three NEEDED libs
that every x86_64 Linux ships, no disk artifacts after the run.

## App author UX

A gcell app intended for shipping has the same source as one you'd
run with `guile -L gcell`, plus one declarative file telling
`gcell-build` what's in the project.

```
my-app/
├── gcell-app.scm
├── src/
│   └── my-app.scm        ; defines (main)
└── assets/               ; optional, bundled verbatim
```

`gcell-app.scm`:

```scheme
(gcell-app
  (name "my-app")           ; binary name + default entry module
  (version "0.1.0")
  (load-paths "src"))       ; dirs added to %load-path at build time
```

`src/my-app.scm`:

```scheme
(define-module (my-app)
  #:use-module (gcell)
  #:export (main))

(define (main)
  (run-app …))
```

By default the entry is the procedure `(main)` in module `(my-app)` —
matching the project's `(name)`. Override with `(entry-module foo
bar)` and `(entry-proc start)` if your layout differs.

Three commands:

- `gcell-build dev` → `guile -L gcell -L src src/my-app.scm`.
  Convenience over the existing dev loop.
- `gcell-build compile` → `guild compile` your `.scm`s into `build/`.
  Speeds up `ship` by avoiding runtime compilation of bundled `.scm`
  on first user-run.
- `gcell-build ship` → produces `dist/<name>`. This is the actual
  ship path.

`gcell-build` itself is a Guile script. It needs `guile` and `guix`
on `$PATH`; it pulls `zig` and `gcc` through `guix shell`.

## How `ship` works

Four phases. Each is independently worth understanding.

### 1. Stage

`gcell-build` builds a flat directory tree at `/tmp/gcell-stage-…/`:

```
/tmp/gcell-stage-my-app-…/
├── site/3.0/
│   ├── gcell.scm
│   ├── gcell/...                  ; gcell's library
│   ├── fibers/...                  ; from guile-fibers-static
│   ├── ice-9/...                   ; from the static guile
│   └── my-app.scm                  ; from your src/
└── site-ccache/
    ├── gcell/*.go                 ; from gcell's build/
    ├── fibers/*.go                 ; pre-compiled
    └── ...                         ; pre-compiled .go for everything else
```

The split mirrors what Guile expects: `share/guile/site/3.0/` for
sources, `lib/guile/3.0/site-ccache/` for compiled bytecode. Apps
provide their `.scm`; gcell and the static toolchain provide the
rest.

### 2. Compile-time embed

`gcell-build` invokes `zig build -Dpayload-dir=…` inside a `guix
shell` that gives access to static-built libguile and a patched
guile-fibers. The Zig build does the heavy lifting:

- `build.zig` walks the staging dir at build time. For each file it
  emits two things into a Zig WriteFile step:
  - A `wf.addCopyFile(staged, relative_path)` so the file lands in
    Zig's generated source tree.
  - An entry in a generated `embed.zig`:
    ```zig
    .{ .path = "site/3.0/gcell/engine.scm",
       .bytes = @embedFile("site/3.0/gcell/engine.scm") },
    ```
- `embed.zig` plus the copied files live in the same WriteFile dir,
  so each `@embedFile` resolves to a sibling. Every byte ends up in
  the binary's `.rodata`.
- `src/main.zig` imports `embed.zig` and uses
  `embed.entries: []const Entry` as the in-memory module table.
- `src/main.zig` is compiled to a `.o`, then `gcc` links it (LLD can't
  follow Guile's fat-LTO archives reliably; gcc with its linker
  plugin can). pkg-config drives the static-libs list; `-Wl,-Bstatic`
  keeps the guile/fibers `-l` flags resolving to `.a`, while system
  libs (pthread, dl, m, c, rt) stay `-Wl,-Bdynamic`.

### 3. The static toolchain

`tools/build/guix.scm` defines the manifest the `guix shell` resolves
to. It's the deepest part of the rabbit hole and the bit you'll never
edit unless you want to add a new bundled C extension.

- `guile-3.0-static` — stock guile with `--disable-static` stripped,
  `--enable-static` added, and `CFLAGS=-ffat-lto-objects` so the
  resulting `libguile-3.0.a` has real ELF object code alongside the
  LTO IR. Without the fat objects, LLD can't link the archive; with
  them, any linker can.
- `with-static` rebuilds bdw-gc, libffi, gmp, libtool, libunistring's
  `static` output is used directly (already shipped by upstream
  Guix). Each gets the same `--enable-static` treatment.
- `guile-fibers-static` is built against `guile-3.0-static`. It also
  carries a build phase that rewrites `(dynamic-call X (dynamic-link
  Y))` in `fibers/events-impl.scm` to `(load-extension Y X)`. This
  matters at runtime — see phase 4.

### 4. Runtime: in-memory load

The produced binary boots and never touches the filesystem for module
loading. The mechanism, in order:

**a. `scm_c_register_extension(NULL, "init_fibers_epoll", …)`** —
called before any Scheme runs. fibers' Scheme calls `(load-extension
"…/fibers-epoll" "init_fibers_epoll")` on its first use; libguile
walks the registered-extensions list before dlopen and finds our
C-side init. Without this, dlopen would drag a second copy of
`libguile.so` into the process and the two SCM tables collide.

**b. Override `try-module-autoload`.** A short Scheme string is
`scm_c_eval_string`'d. It saves the original autoloader, then
`module-define!`s a replacement on the `(guile)` module:

```scheme
(define %orig (@ (guile) try-module-autoload))

(define (%try-embed module-name . rest)
  (let* ((base (string-join (map symbol->string module-name) "/"))
         (go   (string-append "site-ccache/" base ".go"))
         (scm  (string-append "site/3.0/"    base ".scm"))
         (go-bv (%gcell-find go)))
    (cond
     ((and go-bv (false-if-exception ((load-thunk-from-memory go-bv)))) #t)
     ((%gcell-find scm) => (lambda (bv) (%load-scm-bytes bv) #t))
     (else (apply %orig module-name rest)))))

(module-define! (resolve-module '(guile))
                'try-module-autoload %try-embed)
```

`%gcell-find` is a foreign procedure backed by Zig: linear-scan
`embed.entries[]` for a path match, copy the bytes into a fresh
bytevector, return it (or `#f`). The Scheme glue does the rest.

For `.go`, `load-thunk-from-memory` (a built-in from `(system vm
loader)`) takes a bytevector and returns a thunk that evaluates the
bytecode's body. That body is exactly what would have run if the
`.go` had been mmap'd from disk: module setup, exports, top-level
forms.

If the bundled `.go` bytecode is incompatible with the runtime
libguile's version (different sub-minor releases of Guile bump the
format), `load-thunk-from-memory` raises. `false-if-exception` catches
it and the cond falls through to the `.scm` branch: read forms one at
a time out of an `open-bytevector-input-port`, `primitive-eval` each.
Same end state, slightly slower boot.

If neither key hits, the override calls the saved `%orig` — the
real `try-module-autoload`. That walks `%load-path` and finds the
module on disk if the user happens to have it there. Apps that pull
in modules outside the embed bundle still work; the embed table is
just preferred.

**c. The entry call.** `scm_c_resolve_module(opts.entry_module)` and
`scm_c_module_lookup(mod, opts.entry_proc)` find your `(main)`,
`scm_call_0` invokes it. From there it's a normal gcell `run-app`
session.

## Path key vs filesystem path

The keys in `embed.entries[]` look like filesystem paths
(`"site/3.0/gcell/engine.scm"`), but they're never used as paths.
They're dictionary keys into a Zig `[]const Entry` array. We shape
them to match what Guile's autoloader *would* have computed by
walking `%load-path` only because it makes the override's key
derivation a one-liner:

```scheme
(string-append "site-ccache/" (string-join (map symbol->string module-name) "/") ".go")
```

`%load-path` itself is whatever Guile defaults to at boot. We don't
read it, write it, or care what's in it. The override fires *before*
Guile would search it. Disk reads happen only when the embed table
misses, which for a properly-staged bundle means never.

## What's bundled

| Layer        | Bundled                                                |
|--------------|--------------------------------------------------------|
| libguile     | static-linked into the binary                          |
| bdw-gc       | static-linked into the binary                          |
| libffi       | static-linked into the binary                          |
| gmp          | static-linked into the binary                          |
| libunistring | static-linked into the binary                          |
| libltdl      | static-linked into the binary                          |
| guile-fibers | `.scm` + `.go` in the embed table; epoll C ext linked in |
| gcell       | full `.scm` tree + compiled `.go` in the embed table   |
| your app     | `.scm` from `(load-paths …)` in the embed table        |

`libc`, `libm`, `ld-linux` stay dynamic — every distribution provides
them.

## What is NOT bundled (yet)

**macOS / Windows.** The Zig cross-compile path is real (`zig build
-Dtarget=x86_64-macos`), but the toolchain side needs a darwin
libguile-static, a darwin libgc-static, etc., none of which Guix
builds today. Adding them is a Guix package definition exercise. On
Windows, libguile itself is a deeper problem (MSYS2 builds exist, but
the static-link story is harder).

**User-declared extra C extensions.** Bundled is `libguile +
fibers-epoll`. If your app does `(load-extension "libsqlite3"
"init_sqlite")` or pulls in a Guile wrapper around any C library, the
binary won't have those symbols and dlopen will fail (or worse,
succeed and drag a second libguile in).

Each extra extension is a one-time cost, not a per-app cost:

1. Add a `with-static` variant for the C lib to `tools/build/guix.scm`.
2. Have it produce a `libsqlite3.a` (or whatever) into a known location.
3. Add a path to `build.zig` to pick up the `.a` and link it.
4. Add `extern fn init_sqlite3()` to `src/main.zig`, register it via
   `scm_c_register_extension`.
5. Patch the wrapping `.scm` (if it uses `dynamic-call` rather than
   `load-extension`) so the registered init gets found.

The pattern is identical to how guile-fibers is wired today. Once the
wiring lands, every app that uses that extension ships with the same
binary.

## Trade-offs vs. alternatives

| Alternative                                  | What you give up                                  |
|----------------------------------------------|---------------------------------------------------|
| Ship `.scm` + tell users to install Guile    | First-touch friction; users now have a runtime to maintain |
| Ship a tarball (binary + `.scm` sidecar)     | Multiple files; load-path / install instructions  |
| Ship a Flatpak / AppImage / Snap             | Adds a packaging system on top of gcell's own    |
| Use Hoot to compile to Wasm + a wasm runtime | Different perf characteristics; runtime install on the user side |
| Static binary via `tools/build/`             | Build complexity + the 15-20 MB floor             |

The static binary wins if the receiving audience can be told nothing
beyond "download and run."

## Pointers

- `tools/build/README.md` — short-form app-author quickstart.
- `tools/build/src/main.zig` — the 100-line runtime.
- `tools/build/build.zig` — the embed-table generator + link wiring.
- `tools/build/guix.scm` — the static toolchain manifest.
- `tools/build/gcell-build` — the Guile CLI users actually invoke.
