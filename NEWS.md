# Canary news

Changes are listed newest-first.  Format follows
[Keep a Changelog](https://keepachangelog.com).

## 1.0.0 — unreleased

### Added

- **`tools/build/` — `canary-build`, the single-file static-binary
  build tool.**  Wraps a `guix shell` static toolchain (libguile-3.0
  + bdw-gc + libffi + gmp + libunistring + libltdl, all static, plus
  guile-fibers with its epoll C extension statically linked) and a
  Zig-driven link step.  App authors write a `canary-app.scm`
  manifest; `canary-build ship` walks the project, stages canary +
  fibers + the app, and produces a `dist/<name>` ELF — typically
  15-20 MB, `NEEDED` is only `libc/libm/ld-linux`.

  The runtime installs an in-memory `try-module-autoload` override on
  the `(guile)` module; module bytes come from a build-time-generated
  `embed.zig` table baked into `.rodata`.  No cache dir, no XDG
  paths touched, no disk artefacts after the run.  See `SHIPPING.md`
  for the model, `tools/build/README.md` for the quickstart.

  Linux x86_64 only this release.  macOS and user-declared extra C
  extensions deferred.

### Changed (breaking)

- **Stateful nodes return their next state.**  `update` is now a
  pure function on a widget: `(update self msg) -> (cons next-self
  cmd-or-#f)`.  The engine threads the returned `next-self` back into
  the parent's slot and atomically swaps the root between dispatches.
  Slot writes from inside `update` are gone; build the next state
  with `update-slots` and return it paired with the cmd.

  Mechanical migration per stateful node:

  ```
  ;; before
  (define-class <counter> ()
    (n #:init-value 0 #:accessor counter-n))

  (define-method (update (c <counter>) (msg <key>))
    (case (key-sym msg)
      ((#\+) (set! (counter-n c) (+ 1 (counter-n c))))
      ((#\-) (set! (counter-n c) (- (counter-n c) 1))))
    #f)

  ;; after
  (define-class <counter> (<focusable>)
    (n #:init-keyword #:n #:init-value 0 #:getter counter-n))

  (define-method (update (c <counter>) (msg <key>))
    (cons (case (key-sym msg)
            ((#\+) (update-slots c #:n (+ 1 (counter-n c))))
            ((#\-) (update-slots c #:n (- (counter-n c) 1)))
            (else  c))
          #f))
  ```

  Three edits per node: `#:accessor` becomes `#:getter`, every `set!`
  becomes `(update-slots self #:slot val …)`, and the return is a
  pair `(cons next-self cmd-or-#f)` instead of a bare cmd.

### Added

- **`<focusable>` mixin and `update-slots` helper** in `(canary
  widget)`, re-exported from `(canary)`.  Inherit from `<focusable>`
  to give a widget an auto-generated identity slot the engine keys
  focus, mount/unmount, and per-widget subscriptions by — identity
  survives across value-typed updates.  `update-slots` returns a
  fresh instance with the listed slot overrides applied; everything
  else is copied from the source.

- **Engine cascade threads widgets through the tree.**  Each msg
  dispatch walks the rendered view depth-first, calls `update` on
  every widget it finds, and rebuilds the parent so its slot holds
  the returned `next-self`.  Two slots that referenced the same
  widget instance no longer share mutable state; the engine
  preserves widget identity across the cascade via the `<focusable>`
  id.

## 0.2.0 — unreleased

### Added

- **Modes table as discoverable API** (`(canary term modes)`).  A
  single `<mode-state>` slot on `<term>` replaces the five ad-hoc
  boolean slots (auto-margin, insert, keypad, bracketed-paste,
  cursor-visible).  Every ECMA-48 / DEC / xterm mode the parser
  accepts is now declared in `*modes*` with a name, number, kind,
  default, and one-line doc.  Read/write any mode by name:

  ```
  (mode-get (term-modes t) 'cursor-visible)
  (mode-set! (term-modes t) 'sync-output #t)
  ```

  Emit-relevant modes (autowrap, insert, cursor-visible, alt-screen
  variants, bracketed-paste) are wired to their existing consumers.
  Input-side flags (cursor-keys, mouse modes, alt-modifier
  variants) live in the table but no consumer reads them yet --
  Track B will wire those when an input encoder lands.

- **Typed action and op records + `update` dispatch on `<term>`.**
  Two new modules:
  - `(canary term action)` exposes `<action>` / `<action-csi>` —
    the raw, syntactic form of each parsed control sequence.
  - `(canary term dispatch)` defines `<op>` / `<op-set-mode>` /
    `<op-reset-mode>` and routes them to `<term>` through canary's
    existing `update` GOOPS generic.  Specialise `update` at the
    REPL to intercept emulator decisions:

    ```
    (define-method (update t (op <op-set-mode>))
      (engine-log! "mode ~a set" (op-mode-number op))
      (next-method))
    ```

  CSI h/l in the parser now flows through this layer; behaviour is
  unchanged for end users.

- **Stateful UTF-8 byte decoder** (`(canary term utf8)`).  A new
  `<utf8-decoder>` record holds partial codepoint state across calls,
  so byte streams chunked by a `read` (PTY, file, socket) can be
  decoded correctly even when a multi-byte codepoint straddles a
  chunk boundary.  Pair with the new `term-process-bytes!` entry
  point on the parser to feed raw bytevectors directly into a
  `<term>`.

### Fixed

- **Pending-wrap (LCF) at the right margin.**  The terminal emulator
  in `canary/term/` now follows the VT100/xterm spec for autowrap.
  Printing a character at the last column sets a pending-wrap flag
  rather than walking the cursor off the grid; the next print
  consumes the flag (wrapping to column 0 of the next row when
  DECAWM is on, overwriting the last cell when DECAWM is off).
  Any explicit cursor movement (CR, LF, CUP, CUU, CUD, CUF, CUB,
  HPA, VPA, HT, HBT, IND, RI) clears the flag.  Save and restore
  cursor preserve it.

  This corrects a column-edge bug: previously, printing at the last
  column advanced the cursor past the right margin and the next
  print eager-wrapped, producing wrong cell positions for any output
  that relied on the spec behaviour.
