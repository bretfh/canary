# Bench notes

Microbench numbers used to gate architectural decisions.  Numbers are
single-run, single-machine, single-Guile-version — directional, not
authoritative.  When in doubt, re-run before changing course.

Environment:
- Guile 3.0 with autocompile cache primed
- Linux 6.18.26 (kernel detail; CPU and load not pinned)
- Tests warmed (1000 iterations) before timing

## Slice 1 — `update` generic dispatch for control ops

`CSI ?25 h` / `CSI ?25 l` round-trips through:
1. `term-process-output!` parser state machine
2. `dispatch-action!` building an `<action-csi>` record
3. `csi->mode-ops` producing `<op-set-mode>` / `<op-reset-mode>`
4. `update` GOOPS generic dispatch on `(term, <op-*>)`
5. `apply-mode!` setting the slot on `<term>`

Result: **~600k toggles/sec, ~1.67 µs per toggle**.

Real terminal apps emit on the order of tens to hundreds of mode
toggles per second under realistic load (alt-screen swap, mouse mode
changes, kitty kbd push/pop).  1.67 µs each leaves four orders of
magnitude of headroom; control-changing ops can safely route through
the generic.

## Print-path baseline — `term-write!` direct (no generic)

A 76-char ASCII line written into an 80×24 grid via `term-write!`:

**~1.34 M chars/sec, ~746 ns per char**.

Per-frame full-screen redraw of 80×24 = 1920 cells = ~1.4 ms at this
rate.  Acceptable headroom for typical TUI render cadences (60 fps
budget = 16 ms).

This baseline is the gate for any future routing of `<op-print>`
through `update`.  If specialising `update` on `<op-print>` adds
material per-cell overhead, print stays direct (per the plan's
microbench-gated decision).  Recommended rule of thumb: re-run this
baseline against a generic-dispatched print path and reject if cost
exceeds ~10% on a full repaint.

## Slice 2 — `<viewport>` windowing via `#:height` kwarg

100k-item list, ten `txt` items per view, measured over 50-5000 iters:

| config                                  | per view  |
|-----------------------------------------|-----------|
| offset 50000, no height (legacy)        | ~7120 µs  |
| offset 50000, `#:height 30`             | ~137 µs   |
| offset 0,     `#:height 30`             | ~102 µs   |

`#:height` cuts mid-list cost ~52× and top-of-list cost ~70×.  The
residual at offset 50000 is the `(list-tail items 50000)` walk —
linear in offset, not in list length.  True O(visible) needs vector
storage; deferred until someone needs a 10M-item list.

At 137 µs per view, a viewport-heavy app spends 0.8% of a 16 ms frame
budget on the viewport.  Headroom for 60 fps is intact.

## How to reproduce

The bench scripts are inline one-liners — they're not committed as
test files because they're directional, not regression-asserted.  Re-
run via the `guile -L . -c '...'` snippets in the commit message that
introduced this file, or the equivalent under whatever script harness
is current at the time of re-bench.
