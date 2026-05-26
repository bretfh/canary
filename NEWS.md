# Canary news

Changes are listed newest-first.  Format follows
[Keep a Changelog](https://keepachangelog.com).

## 0.2.0 — unreleased

### Added

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
