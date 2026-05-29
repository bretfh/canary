# canary-build

Ship a canary app as a single Linux static binary, ~16 MB. End users
download the binary and run it; no Guile install required.

This tool is opt-in. canary the library doesn't need it. If you're
writing a canary app and you're happy running it via `guile -L canary
myapp.scm` for yourself, you don't need this.

## Install

From the canary repo root:

```
make tool-install
```

Drops `canary-build` into `~/.local/bin/`. Requires `guix` on PATH.

## App project layout

```
my-app/
├── canary-app.scm
├── src/
│   └── my-app.scm         ; entry module — defines (main)
└── assets/                ; optional, bundled verbatim
```

`canary-app.scm`:

```scheme
(canary-app
  (name "my-app")                 ; binary name + default entry module
  (version "0.1.0")
  (load-paths "src"))             ; dirs added to %load-path at build time
```

`src/my-app.scm`:

```scheme
(define-module (my-app)
  #:use-module (canary)
  #:export (main))

(define (main)
  (run-app …))
```

The default entry is `(main)` in module `(my-app)` (i.e. matching
`(name)`). Override with `(entry-module foo bar)` and `(entry-proc
start)` in `canary-app.scm` if your app is laid out differently.

## Commands

- `canary-build dev` — convenience for `guile -L canary -L src
  src/my-app.scm`.
- `canary-build compile` — `guild compile` your `.scm`s under `build/`
  (faster ship later).
- `canary-build ship` — produces `dist/<name>` (a static ELF) and
  `dist/payload.tar` (the staged Scheme tree, kept for debugging).

End user runs `./dist/my-app`. On first run the binary extracts its
embedded payload to `${XDG_CACHE_HOME:-~/.cache}/canary/<hash>/` and
sets `GUILE_LOAD_PATH` at it. Subsequent runs skip extraction. A
re-shipped binary hashes differently and gets a fresh cache dir, so
old payloads coexist until the operator wipes `~/.cache/canary/`.

## What's bundled

- libguile + transitive deps (bdw-gc, libffi, libgmp, libunistring,
  libltdl) all static.
- guile-fibers with its epoll C extension statically linked, the
  Scheme side patched to use `load-extension` against a registered
  init so dlopen is bypassed.
- The full canary module tree at the version sitting in this repo.
- Your app's `.scm` from `(load-paths …)` and `.go` from `build/` if
  present.

## What is NOT bundled (v1)

- macOS or Windows targets. The Zig cross-compile path is real but
  needs a darwin/MSYS libguile static build. Linux x86_64 only.
- User-declared extra C extensions (sqlite, gnutls, etc.). Each extra
  extension is a one-time cost: patch
  `tools/build/guix.scm` to add a static variant of the library +
  extension; add an `extern fn` + `scm_c_register_extension` to
  `tools/build/src/main.zig`; relink. The pattern is fixed; the
  per-extension wiring is mechanical. Not yet exposed through
  `canary-app.scm`.
- Glibc itself. The binary needs `libc.so.6` / `libm.so.6` /
  `ld-linux-x86-64.so.2` on the target. Modern x86_64 Linux ships
  these.

## Files

| File                         | Role                                               |
|------------------------------|----------------------------------------------------|
| `canary-build`               | Guile CLI: `dev` / `compile` / `ship` commands     |
| `build.zig`                  | Zig build: compile `main.zig` → `.o`, gcc-link static |
| `guix.scm`                   | Manifest for `guix shell -m …` — static variants of guile + fibers |
| `src/main.zig`               | Runtime: register fibers ext, extract payload, boot Guile, call entry |
| `templates/canary-app.scm.tmpl` | Starter manifest for `canary-build init` (stretch) |
