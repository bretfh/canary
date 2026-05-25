# canary — design

A live-coded TUI library for Guile. View tree + per-node state + a msg
cascade. No GOOPS in author code.

Two bets that shape every decision:

1. **View is a tree, not a styled string.** Composition, overlays,
   sizing and diffing are engine primitives. The user describes
   structure; the engine handles cells. The axis tea+lipgloss don't
   cover — they hand the user strings to concatenate and styles to
   chain.

2. **Styling is a palette + boolean flags.** `#:fg`/`#:bg` accept a
   hex string *or* a palette name (`#:fg 'accent`). Attribute flags
   are individual booleans (`#:bold`, `#:italic`). Multiple palettes
   register under one theme; `(cycle-palette)` swaps the active one
   and every palette-named reference recolors. No `if dark-mode-then`
   at call sites, no separate style-name layer.

Aim: clearer than tea+lipgloss for visual/composable TUIs, with
REPL-driven iteration. Not optimising for smallest binary, lowest
baseline CPU, or ecosystem size.

## Architecture

Everything is a **node**. Layout primitives (`txt`, `vbox`, `hbox`,
`boxed`, …) are nodes. Stateful UI elements (textinput, panel, your
app's root) are also nodes — they're `<stateful>` nodes carrying a
mutable state record and three procs:

```
view-proc  : (lambda (self) → child-node)
react-proc : (lambda (self msg) → #f | cmd)        ; optional
init-proc  : (lambda (self) → unspecified)          ; optional
```

State mutates in place through setters; return values from view/react/
init are not used to replace state. `react-proc` returns `#f` for no
effect or a cmd value (see [Cmds](#cmds)).

The engine:

- runs the channel-backed event loop
- reads input (keys, mouse) and emits typed msgs
- renders the view tree, populates click regions, draws cell diffs
- on each msg, walks the rendered tree depth-first and calls every
  stateful's `react-proc` with the msg (the **cascade**)
- collects cmds returned from react, batches them, runs them
- spawns fibers for cmds that need them (`every`, `after`, user thunks)

No fixed-fps render loop — render runs after any msg that produced
something to redraw. Authors never construct `<engine>`; they pass a
root node to `run-app` and the engine wraps it.

### The cascade

Every stateful in the rendered tree sees every msg. This is closer to
actor-style broadcast than to Elm-TEA's single update or React's
parent-to-child props. Each node filters in its own `react-proc` —
typically with `(when (key? msg) ...)` or `(case (and (symbol? msg) msg) ...)`.

The tree IS the children. No `widget-children` declaration to keep in
sync; the engine pulls children by calling `view-proc`, then walks the
returned node. Containers (vbox, boxed, overlay, …) are walked
transparently.

## A "hello, world" app

```scheme
(use-modules (canary))

(define-node hello
  #:state ((greeting "world"))
  #:view  (lambda (self)
            (txt "hello, " (txt (hello-greeting self) #:fg 'accent #:bold))))

(run-app (make-hello)
         #:keymap (keymap (bind #\q 'quit)))
```

`define-node` generates the state record, per-slot accessors
(`hello-greeting` / `set-hello-greeting!`), a predicate (`hello?`),
and a constructor (`make-hello [#:greeting ...]`) returning a
`<stateful>` node ready to drop into a tree.

## `define-node`

The author surface. Expansion:

```scheme
(define-node counter
  #:state ((n 0)
           (label "count"))
  #:view  (lambda (self)
            (txt (counter-label self) ": " (number->string (counter-n self))))
  #:react (lambda (self msg)
            (case (and (symbol? msg) msg)
              ((bump) (set-counter-n! self (+ 1 (counter-n self))))
              (else #f)))
  #:init  (lambda (self) #f))         ; optional
```

generates:

- a hidden state record (slots not visible to user code)
- public per-slot accessors: `counter-n`, `set-counter-n!`,
  `counter-label`, `set-counter-label!`
- public predicate `counter?`
- public constructor `(make-counter [#:n 0] [#:label "count"])` →
  `<stateful>`

Required: `#:state` (use `#:state ()` for stateless) and `#:view`.
`#:react` and `#:init` are optional.

`view-proc` should be pure. The cascade walker calls it to find the
node's children before the renderer calls it to produce cmds; side
effects fire twice. Read `(*frame-size*)` inside view if the layout
needs to know the terminal size.

## Msgs

Engine-emitted records matched in `react-proc`.

| record       | when                                          |
|--------------|-----------------------------------------------|
| `<key>`      | a keystroke (with optional modifiers)         |
| `<mouse>`    | mouse button / motion / scroll                |
| `<tick>`     | an `every` or `after` fired                   |
| `<resize>`   | terminal size changed                         |
| `<focus>`    | terminal gained focus                         |
| `<blur>`     | terminal lost focus                           |
| `<resume>`   | engine reacquired tty after suspend           |
| symbol       | keymap action; `on-click` action; user msg    |
| list         | any user-defined shape via `(send eng …)`     |

Idiomatic react:

```scheme
#:react
(lambda (self msg)
  (cond
   ((key? msg)
    (case (key-sym msg)
      ((#\q) 'quit)
      (else  #f)))
   ((tick? msg)
    (set-self-frame! self (+ 1 (self-frame self)))
    #f)
   ((eq? msg 'bump)
    (set-self-n! self (+ 1 (self-n self)))
    #f)
   (else #f)))
```

Return either `#f` (no cmd) or a cmd value. Cascade collects cmds from
every reacting node, batches them, dispatches.

## Cmds

Returned from `react-proc` and `init-proc`. Cmds are constructor
calls, not quoted literals.

| cmd                                 | effect                                       |
|-------------------------------------|----------------------------------------------|
| `#f`                                | no-op                                        |
| `'quit`                             | exit `run-app`                               |
| `(batch c1 c2 …)`                   | parallel                                     |
| `(sequence c1 c2 …)`                | sequential, awaits each                      |
| `(every #:hz N producer)`           | persistent ticker — one fiber, no reschedule |
| `(every #:ms N producer)`           | same                                         |
| `(every #:seconds S producer)`      | same                                         |
| `(after #:ms N producer)`           | one-shot timer                               |
| `(println "string" …)`              | line to scrollback above alt-screen          |
| `(set-title "name")`                | runtime OS title change                      |
| `(clear-screen)`                    | force full repaint                           |
| `(cursor 'hidden│'visible│'bar│…)`  | runtime cursor change                        |
| `(alt-screen 'on│'off)`             | runtime alt-screen toggle                    |
| `(mouse-mode 'off│'click│'cell│'all)` | runtime mouse mode change                  |
| `(set-palette 'name)`               | switch active palette                        |
| `(cycle-palette)`                   | next palette in theme's declared order       |
| `(suspend)`                         | hand tty to shell, resume on SIGCONT         |
| `(exec "cmd args" #:on-done thunk)` | tear down, run process, restore, msg         |
| user thunk                          | engine spawns fiber; thunk returns msg       |

The engine intercepts `'quit` directly. Everything else routes
through `(canary cmd)`.

## Click & hover

```scheme
(on-click action child)
(on-hover child styler-proc)
```

`on-click` wraps any child so a left-press inside its rendered rect
dispatches `action` as a msg through the cascade. `action` is any
value — a symbol, a list, anything `react-proc`s can match on.

`on-hover` swaps `child` for `(styler-proc child)` whenever the cursor
is inside the rect — purely visual, no msg.

```scheme
(on-click 'save
          (on-hover (txt " save " #:fg 'muted)
                    (lambda (_) (txt " save " #:fg 'accent #:bold))))
```

## Keys and keymap

```scheme
(keymap
 (bind k1 [k2 …] action [#:timeout-ms N])
 …)
```

A key is one of:

| form                                              | meaning                              |
|---------------------------------------------------|--------------------------------------|
| `#\h`, `#\?`, `#\:`                               | literal char                         |
| `#\tab`, `#\escape`, `#\space`, `#\return`, `#\delete`, `#\backspace` | Guile's named chars |
| `'left`, `'right`, `'up`, `'down`, `'home`, `'end`, `'pgup`, `'pgdn`, `'f1`…`'f12` | symbols |
| `'(#\x ctrl)`, `'(left ctrl)`, `'(#\tab shift)`   | modifier list                        |
| `'(mouse left)`, `'(mouse right)`, `'(mouse middle)` | mouse button                      |
| `'(mouse-scroll up)`, `'(mouse-scroll down)`      | scroll wheel                         |

Modifiers: `control`/`ctrl`, `alt`/`meta`/`option`, `shift`,
`super`/`cmd`/`command`. Canonicalised, sorted, deduped internally.

```scheme
(bind #\q 'quit)                          ; single key
(bind 'escape 'cancel)                    ; named key
(bind '(#\x ctrl) 'cut)                   ; modified
(bind #\g #\g 'top #:timeout-ms 500)      ; sequence with timeout
(bind '(#\x ctrl) '(#\s ctrl) 'save)      ; modified sequence
(bind '(mouse left) 'select)              ; mouse
```

The action can be any value. `'quit` is engine-intercepted. Anything
else is cascaded as a msg.

## Theme

Named palettes of hex colors; multiple palettes register under one
theme; `(cycle-palette)` walks them.

```scheme
(define ui
  (theme
   (palette dark
     (bg     "#0a0d18")
     (fg     "#d8d2c2")
     (muted  "#5a6378")
     (accent "#ffd05e")
     (note   "#ff6b9d"))

   (palette light
     (bg     "#f8f5ec")
     (fg     "#1a1a1a")
     (muted  "#605850")
     (accent "#a06b14")
     (note   "#c01666"))))
```

- `palette` blocks list named hex colors. First declared is the default.
- Every palette must define the same set of names. Names not present
  in every palette fall back to the default palette's value when
  swapped.
- Engine tracks the registered palettes; `(cycle-palette)` and
  `(set-palette 'light)` work without the user maintaining a list.

No style-name layer. To reuse a styling combo, define a helper:

```scheme
(define (hint s) (txt s #:fg 'muted #:italic))
(define (note s) (txt s #:fg 'note  #:bold))
```

Helpers are ordinary procs in user code, not a separate engine concept.

## View nodes

`txt` accepts strings, nested `txt` nodes (inline spans), and styling
kwargs:

```scheme
(txt "hello")
(txt "hello" #:fg 'accent #:bold)
(txt "saved: " (txt name #:fg 'note #:bold))   ; nested = inline span
(txt "tmp" #:fg "#ff0000")                     ; inline hex
```

Kwargs:

- `#:fg` / `#:bg` — hex string (`"#abc123"`) or palette name (`'accent`)
- `#:bold` `#:italic` `#:underline` `#:reverse` `#:strike` `#:dim` —
  individual boolean flags. **No `#:attrs '(bold italic)` list.**

Layout primitives:

```scheme
(vbox a b c)
(hbox a b c)
(spacer n)                                ; height in vbox
(spacer #:w n)                            ; width  in hbox
(pad    child #:top n #:left n …)         ; inner whitespace
(margin child #:top n #:left n …)         ; outer whitespace
(align  child 'left│'center│'right #:width n)
(width  child n)
(height child n)
(fill   w h #:bg 'name-or-hex)
(pin    col row child)
(overlay base p1 p2 …)
(boxed  child #:border border-rounded #:fg 'name-or-hex #:title "name")
(static child)                            ; cache rendered cmds keyed on rect
(on-click action child)
(on-hover child styler-proc)
```

`pad` and `margin` are distinct on purpose: `pad` adds space *inside*
a boxed/styled region, `margin` adds space *outside*. Lipgloss
conflates them; canary keeps them separate.

## Components

Each is a `define-node`. Embed by dropping the result of `make-X`
into your tree; the cascade routes msgs to them automatically.

```scheme
(define-node tweet
  #:state ((input  (make-textinput #:prompt "> "))
           (notes  '()))
  #:view (lambda (t)
           (vbox (tweet-input t)
                 (txt (format #f "~a notes" (length (tweet-notes t)))))))
```

No `react` forwarding needed — `tweet-input t` IS a stateful node in
the rendered tree, so the cascade hits it directly.

Bundled: `textinput`, `button`, `progress`, `spinner`, `paginator`,
`panel`.

## Live coding

```
make run
```

Launches the app and exposes a Geiser-listenable Guile image on
`localhost:37146`. From an Emacs/VS Code Geiser session:

- redefine a node's view-proc or react-proc — the wrapper holds a
  reference, so the next render/cascade picks up the new closure
  *after* recreating the node. To swap behaviour live without
  reconstruction, dispatch on a slot rather than capturing in the
  closure body.
- mutate slots of any live stateful directly between events
- re-evaluate the theme to swap palettes or restyle

No rebuild loop. The instance and process state survive code changes.

## Anti-patterns

- **Don't** return state from react/init. Mutate via the setters
  `define-node` generates; return `#f` or a cmd from react, nothing
  from init. The engine ignores returned state.
- **Don't** declare a parent's children separately. The tree IS the
  children — if a node appears in another node's `view-proc` output,
  it's wired automatically.
- **Don't** construct cmds as quoted lists: `'(set-title "x")` ✗,
  `(set-title "x")` ✓.
- **Don't** put style flags in a list: `#:attrs '(bold italic)` ✗,
  `#:bold #:italic` ✓.
- **Don't** thread palette lists in user code. Declare palettes inside
  `theme`; `cycle-palette` iterates them.
- **Don't** look for a `#:style` kwarg on `txt`. Reference palette
  colors through `#:fg`/`#:bg`; bundle reuse with a helper proc.
- **Don't** poll for state changes. Every transition is a msg; every
  side-effect is a cmd.
- **Don't** issue `(alt-screen 'on)` / `(cursor 'hide)` / `(set-title
  …)` from `init` for the defaults. Pass them as kwargs to `run-app`.
- **Don't** side-effect inside `view-proc`. The cascade walker calls
  it once to find children before render calls it again to produce
  cmds; any effect fires twice per msg.

## What canary doesn't try to do

- A statically-typed API. Match patterns and runtime checks are honest
  about the dynamic-Scheme nature.
- A single statically-linked binary. The runtime is Guile + fibers.
- Sub-millisecond idle CPU. Native Go beats this in absolute terms; the
  intentional trade is REPL-driven dev and a richer view IR.
- A wide ecosystem of pre-built widgets. The bundled components cover
  the common cases; the design favours composition over a sprawling
  library.

## Module surface

```scheme
(use-modules (canary))
```

Re-exports every public name from:

- `(canary engine)`      — `run-app`, `start-engine!`, `send`, log entries
- `(canary cmd)`         — `run-command`
- `(canary node)`        — `define-node`
- `(canary view)`        — `<stateful>`, `make-stateful`, `view-size`,
                           `view-node?` (escape hatch — most authors use
                           `define-node`)
- `(canary protocol)`    — msg types + cmd constructors
- `(canary key)`         — `<key>`, `key`, `key=?`, modifier helpers
- `(canary keymap)`      — `keymap`, `bind`
- `(canary theme)`       — `theme`, palette forms
- `(canary layout)`      — `txt`, `vbox`, `hbox`, `spacer`, `pad`,
                           `margin`, `align`, `width`, `height`, `fill`,
                           `pin`, `overlay`, `static`, `on-click`,
                           `on-hover`
- `(canary borders)`     — `boxed`, `border-normal`, `border-rounded`,
                           `border-thick`, `border-double`, `border-ascii`
- `(canary backend-ansi)` — `make-ansi-backend`

Components are imported individually:

```scheme
(use-modules (canary)
             (canary components textinput)
             (canary components spinner))
```
