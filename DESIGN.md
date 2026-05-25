# canary

A TUI library for Guile. You describe the screen as a tree, the engine
turns it into terminal cells. Edit your code in the REPL and the next
render reflects the change.

The unit is a **node**. `vbox`, `txt`, `boxed` are nodes. A spinner is
a node. A file browser is a node. Your whole app is a node. Nodes nest
in other nodes; the engine walks one tree.

Stateful nodes mutate themselves in place, returning cmds when they
want the engine to do something — start a timer, swap palettes, quit.

Color is by name. `#:fg 'accent` reads from the active palette;
`(cycle-palette)` flips palettes and every reference recolors at once.
Styling attributes are individual flags (`#:bold #:italic`), not a
list.

## Hello, counter

```scheme
(use-modules (canary) (oop goops))

(define-class <counter> ()
  (n #:init-keyword #:n #:init-value 0 #:accessor counter-n))

(define-method (view (c <counter>) sz)
  (txt (number->string (counter-n c))))

(define-method (update (c <counter>) (msg <key>) sz)
  (case (key-sym msg)
    ((#\+) (set! (counter-n c) (+ 1 (counter-n c))) (values c #f))
    ((#\-) (set! (counter-n c) (- (counter-n c) 1)) (values c #f))
    (else  (values c #f))))

(define-method (update (c <counter>) msg sz) (values c #f))

(run-app (make <counter>)
         #:title  "counter"
         #:keymap (keymap (bind 'escape 'quit)))
```

That's everything. A GOOPS class for state, methods for `view` and
`update`, `run-app` to launch.

## Architecture

Three generics drive every node:

```
view   : (lambda (self sz)     → child-node)
update : (lambda (self msg sz) → (values self cmd-or-#f))   ; optional
init   : (lambda (self)        → cmd-or-#f)                 ; optional
```

Specialise them on your class. Layout records (`txt`, `vbox`, `hbox`,
`boxed`, `pad`, `align`, `width`, `height`, `overlay`, `pin`,
`on-click`, `on-hover`) are pure data — no methods, no state. The
renderer walks them by type-check. When it reaches a GOOPS instance
in the tree, it calls `(view instance sz)` to expand.

The engine:

- runs a channel-backed event loop
- reads input (keys, mouse) and emits typed msgs
- renders `(view root sz)`, populates click regions, draws cell diffs
- on each msg, walks the rendered tree and calls `(update node msg sz)`
  on every GOOPS instance found
- collects cmds from each update's second return value, batches them,
  runs them
- spawns fibers for cmds that need them (`every`, `after`, user thunks)

`run-app` takes any GOOPS instance and config kwargs. No `<app>` base
class to subclass — your class inherits from whatever you want, or
nothing.

### Composition

`view` returns a tree containing other nodes — layout records or
GOOPS instances — and the engine handles the rest.

```scheme
(define-class <chat> ()
  (lines #:init-value '()                #:accessor chat-lines)
  (input #:init-form (make-textinput)    #:accessor chat-input))

(define-method (view (c <chat>) sz)
  (vbox (apply vbox (map (lambda (l) (txt l)) (chat-lines c)))
        (view (chat-input c) sz)))
```

The cascade visits both `<chat>` and the embedded `<textinput>` on
every msg. Each `update` decides what to do or returns `(values self
#f)` to ignore.

## Live coding

```
make repl
```

opens a Geiser-listenable image. From an Emacs/VS Code Geiser session:

- `C-M-x` on a `(define-method (view (c <counter>) sz) …)` form
  replaces the method body. Existing instances dispatch to the new
  body on the next render.
- `C-M-x` on a `(define-class <counter> () …)` form triggers Guile's
  class-redefinition protocol. Existing instances migrate to the new
  slot layout.
- `(set! (counter-n c) 99)` from the REPL mutates a slot directly.
- Re-evaluate a theme to swap palettes or restyle.

No rebuild loop. The process keeps running across edits.

## Msgs

Engine-emitted records matched in `update`.

| record    | when                                          |
|-----------|-----------------------------------------------|
| `<key>`   | a keystroke (with optional modifiers)         |
| `<mouse>` | mouse button / motion / scroll                |
| `<tick>`  | an `every` or `after` cmd fired               |
| `<resize>`| terminal size changed                         |
| `<init>`  | once before the first user input              |
| `<focus>` | terminal gained focus                         |
| `<blur>`  | terminal lost focus                           |
| `<resume>`| engine reacquired tty after suspend           |
| symbol    | keymap action; `on-click` action; user msg    |
| list      | any user-defined shape via `(send eng …)`     |

Multi-method dispatch on the msg class is the natural shape:

```scheme
(define-method (update (c <my>) (msg <tick>) sz) …)
(define-method (update (c <my>) (msg <key>)  sz) …)
(define-method (update (c <my>) msg sz) (values c #f))   ; catch-all
```

## Cmds

Returned from `update` (second value) and `init`. Cmds are constructor
calls, not quoted literals.

| cmd                                 | effect                                  |
|-------------------------------------|-----------------------------------------|
| `#f`                                | no-op                                   |
| `'quit`                             | exit `run-app`                          |
| `(batch c1 c2 …)`                   | parallel                                |
| `(sequence c1 c2 …)`                | sequential, awaits each                 |
| `(every #:hz N producer)`           | persistent ticker — one fiber           |
| `(every #:ms N producer)`           | same                                    |
| `(after #:ms N producer)`           | one-shot timer                          |
| `(println "string" …)`              | line to scrollback above alt-screen     |
| `(set-title "name")`                | runtime OS title change                 |
| `(clear-screen)`                    | force full repaint                      |
| `(cursor 'hidden│'visible│'bar│…)`  | runtime cursor change                   |
| `(alt-screen 'on│'off)`             | runtime alt-screen toggle               |
| `(mouse-mode 'off│'click│'cell│'all)` | runtime mouse mode change             |
| `(set-palette 'name)`               | switch active palette                   |
| `(cycle-palette)`                   | next palette in theme's declared order  |
| `(suspend)`                         | hand tty to shell, resume on SIGCONT    |
| `(exec "cmd args" #:on-done thunk)` | tear down, run process, restore, msg    |
| user thunk                          | engine spawns fiber; thunk returns msg  |

## Click & hover

```scheme
(on-click action child)
(on-hover child styler-proc)
```

`on-click` wraps any child so a left-press inside its rendered area
dispatches `action` as a msg. `on-hover` swaps `child` for
`(styler-proc child)` whenever the cursor is inside the area — purely
visual.

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

| form                                    | meaning                    |
|-----------------------------------------|----------------------------|
| `#\h`, `#\?`, `#\:`                     | literal char               |
| `#\tab` `#\escape` `#\space` `#\return` `#\delete` `#\backspace` | named chars |
| `'left` `'right` `'up` `'down` `'home` `'end` `'pgup` `'pgdn` `'f1`…`'f12` | symbols |
| `'(#\x ctrl)` `'(left ctrl)`            | modifier list              |
| `'(mouse left)` `'(mouse right)`        | mouse button               |
| `'(mouse-scroll up)` `'(mouse-scroll down)` | scroll wheel           |

Modifiers: `control`/`ctrl`, `alt`/`meta`/`option`, `shift`,
`super`/`cmd`/`command`. Canonicalised, sorted, deduped internally.

```scheme
(bind #\q 'quit)
(bind 'escape 'cancel)
(bind '(#\x ctrl) 'cut)
(bind #\g #\g 'top #:timeout-ms 500)
(bind '(mouse left) 'select)
```

`'quit` is engine-intercepted. Anything else is dispatched to
`update`.

## Theme

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
- Every palette should define the same set of names. Names not present
  in every palette fall back to the default palette's value when
  swapped.
- The engine tracks registered palettes; `(cycle-palette)` and
  `(set-palette 'light)` work without the user maintaining a list.

For reusable styling combos, define a helper:

```scheme
(define (hint s) (txt s #:fg 'muted #:italic))
(define (note s) (txt s #:fg 'note  #:bold))
```

## Layout primitives

```scheme
(txt "hello")
(txt "hello" #:fg 'accent #:bold)
(txt "saved: " (txt name #:fg 'note #:bold))   ; nested = inline span
(txt "tmp" #:fg "#ff0000")                     ; inline hex
```

Styling kwargs on `txt`:

- `#:fg` / `#:bg` — hex string (`"#abc123"`) or palette name (`'accent`)
- `#:bold` `#:italic` `#:underline` `#:reverse` `#:strike` `#:dim` —
  individual boolean flags.

Containers:

```scheme
(vbox a b c)
(hbox a b c)
(spacer n)                                ; height in vbox
(spacer #:w n)                            ; width  in hbox
(pad    child #:top n #:left n …)         ; inner whitespace
(margin child #:top n #:left n …)         ; outer whitespace
(align  child 'left│'center│'right #:width n)
(width  child n)
(height child n #:valign 'top│'center│'bottom)
(fill   w h #:bg 'name-or-hex)
(pin    col row child)
(overlay base p1 p2 …)
(boxed  child #:border border-rounded #:fg 'name #:title "name")
(static child)                            ; cache rendered cmds keyed on rect
(on-click action child)
(on-hover child styler-proc)
```

`pad` and `margin` are distinct: `pad` adds space *inside* a
boxed/styled region, `margin` adds space *outside*.

## Bundled components

Plain GOOPS classes in `canary/components/`:

- `<button>` — title + on-click
- `<panel>`  — title + border + footer + content, with hover affordance
- `<textinput>` — single-line input with cursor
- `<spinner>` — animated frames, installs its own ticker via `init`
- `<progress>` — bar with percentage
- `<paginator>` — page indicator with key bindings

Each exposes `make-X` as the constructor and a small set of accessors.
Embed an instance as a slot on your app class; the engine cascades
msgs into it automatically.

## Anti-patterns

- **Don't** return new state from `update`. Mutate in place with the
  accessors, return `(values self cmd)`.
- **Don't** construct cmds as quoted lists: `'(set-title "x")` ✗,
  `(set-title "x")` ✓.
- **Don't** put style flags in a list: `#:attrs '(bold italic)` ✗,
  `#:bold #:italic` ✓.
- **Don't** poll for state changes. Every transition is a msg; every
  side-effect is a cmd.
- **Don't** issue `(alt-screen 'on)` / `(cursor 'hide)` / `(set-title
  …)` from `init` for the defaults. Pass them as kwargs to `run-app`.
- **Don't** side-effect inside `view`. The cascade walker calls it
  once to find children before render calls it again to produce
  cmds; any effect fires twice per msg.

## Module surface

```scheme
(use-modules (canary))
```

Re-exports the public surface — `view`, `update`, `init` generics,
layout primitives, theme/palette forms, keymap helpers, msg + cmd
constructors, `run-app`, `send`, `<key>` / `<mouse>` / `<tick>` etc.
See `canary.scm` for the full list.

Components are imported individually:

```scheme
(use-modules (canary)
             (canary components panel)
             (canary components textinput))
```
