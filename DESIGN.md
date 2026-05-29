# canary

A TUI library for Guile. You describe the screen as a tree, the engine
turns it into terminal cells. Edit your code in the REPL and the next
render reflects the change.

The unit is a **node**. `vbox`, `txt`, `boxed` are nodes. A spinner is
a node. A file browser is a node. Your whole app is a node. Nodes nest
in other nodes; the engine walks one tree.

Stateful nodes return their next state paired with an optional cmd.
A node's `update` produces `(cons next-self cmd-or-#f)`; the engine
threads the next-self back into the tree and swaps the root between
dispatches.  Use `update-slots` to build the next state with a few
slot overrides; the rest carry over unchanged.

Color is by name. `#:fg 'accent` reads from the active palette;
`(cycle-palette)` flips palettes and every reference recolors at once.
Styling attributes are individual flags: `#:bold`, `#:italic`,
`#:underline`, `#:reverse`, `#:strike`, `#:dim`.

## API

Dev loop is `guile -L /path/to/canary myapp.scm`. Live-coding via
geiser, evaluate forms into a running app, etc. — the live-coding
section near the bottom of this doc covers it. Shipping a finished
app to end users without making them install Guile is covered in
`SHIPPING.md` and isn't a topic here.

```scheme
(use-modules (canary))
```

Brings in:

- `run-app`, `send`
- Generics: `view`, `update`
- Msg classes: `<key>`, `<mouse>`, `<tick>`, `<resize>`, `<init>`,
  `<mount>`, `<unmount>`, `<paste>`, `<focus>`, `<blur>`, `<resume>`
  (plus accessors: `key-sym`, `mouse-x`, `tick-n`, `resize-width`,
  `paste-text`, ...)
- Cmd constructors: `every`, `after`, `batch`, `sequence`, `focus`,
  `cancel`, `set-title`, `cursor`, `alt-screen`, `mouse-mode`,
  `clear-screen`, `println`, `suspend`, `exec`, `set-palette`,
  `cycle-palette`
- Layout: `txt`, `vbox`, `hbox`, `spacer`, `pad`, `margin`, `align`,
  `width`, `height`, `fill`, `pin`, `overlay`, `boxed`, `static`,
  `on-click`, `on-hover`, `link`, `prompt-zone`, `input-zone`,
  `output-zone`, `flex`, `wrap`, `image`, `with-keymap`
- Borders: `border-normal`, `border-rounded`, `border-thick`,
  `border-double`, `border-ascii`
- Theme: `theme`, `palette`, `theme-set!`, `theme-cycle!`,
  `default-theme`
- Keymap: `keymap`, `bind`, `with-keymap`
- Backend: `<ansi-backend>`, `ansi-backend`, `graphics?`, `cell-w`,
  `cell-h`

Components live in separate modules and are imported individually:

```scheme
(use-modules (canary components panel)
             (canary components textinput)
             (canary components spinner))
```

The VT emulator core is also a public library; pull it in with
`(use-modules (canary term))` when you want to parse, snapshot, or
replay terminal byte streams directly.

The sections below cover each piece.

## Hello, counter

```scheme
(use-modules (canary) (oop goops))

(define-class <counter> (<focusable>)
  (n #:init-keyword #:n #:init-value 0 #:getter counter-n))

(define-method (view (c <counter>))
  (txt (number->string (counter-n c))))

(define-method (update (c <counter>) (msg <key>))
  (cons (case (key-sym msg)
          ((#\+) (update-slots c #:n (+ 1 (counter-n c))))
          ((#\-) (update-slots c #:n (- (counter-n c) 1)))
          (else  c))
        #f))

(run-app (make <counter>)
         #:title  "counter"
         #:keymap (keymap (bind 'escape 'quit)))
```

That's everything. A class for state, methods for `view` and
`update`, `run-app` to launch.

## Architecture

Two generics drive every node:

```
view   : (lambda (self)     -> node)
update : (lambda (self msg) -> (cons next-self cmd-or-#f))   ; optional
```

Stateful nodes inherit from `<focusable>` so they carry an
auto-generated identity slot the engine keys focus, mount/unmount,
and per-widget subs by.  Read slots with their `#:getter`
accessors; build the next state with `update-slots`.

Specialise them on your class. Startup logic is just `update`
specialised on the `<init>` msg:

```scheme
(define-method (update (c <my-app>) (msg <init>))
  (cons c (load-cmd c)))             ; same (next, cmd) pair as every update
```

Layout primitives like `flex`, `align`, and `wrap` don't have a
fixed size — they reflow against the rect they're handed at render
time, so the same tree adapts when the terminal resizes.

For widgets that need to *read* the terminal size (animation budgets,
viewport sizing), capture `<resize>` into a slot:

```scheme
(define-class <my-app> (<focusable>)
  (cols #:init-value 80 #:getter my-cols)
  (rows #:init-value 24 #:getter my-rows)
  ...)

(define-method (update (a <my-app>) (msg <resize>))
  (cons (update-slots a
          #:cols (resize-width msg)
          #:rows (resize-height msg))
        #f))
```

Layout records — `txt`, `vbox`, `hbox`, `boxed`, `pad`, `margin`,
`align`, `width`, `height`, `fill`, `spacer`, `overlay`, `pin`,
`static`, `on-click`, `on-hover`, `link`, `prompt-zone`,
`input-zone`, `output-zone`, `flex`, `wrap`, `image` — are pure
data values composed into a tree. The renderer walks them by type
check; when it reaches a widget, it calls `(view widget)` to
expand.

The engine:

- runs a channel-backed event loop
- reads input (keys, mouse) and emits typed msgs
- renders `(view root)`, populates click regions, draws cell diffs
- on each msg, walks the rendered tree and calls `(update node msg)`
  on every widget found
- collects each update's returned cmd, batches them, runs them
- spawns fibers for cmds that need them (`every`, `after`, user thunks)

`run-app` takes any widget plus config kwargs.

### Composition

`view` returns a tree of nodes: layout records and widgets composed
freely. Embed widgets by reference. The renderer calls `view` on each
widget during walk; the cascade dispatches `update` on every widget
it finds. Every layout primitive accepts widgets and layout records
interchangeably.

```scheme
(define-class <chat> (<focusable>)
  (lines #:init-value '()             #:getter chat-lines)
  (input #:init-form (textinput) #:getter chat-input))

(define-method (view (c <chat>))
  (vbox (apply vbox (map (lambda (l) (txt l)) (chat-lines c)))
        (chat-input c)))                ; <- the <textinput>, not (view it)
```

Nest as deep as you want:

```scheme
(vbox
 (boxed (dired #:path "/foo") #:title "left")
 (hbox  (align (spinner) #:h 'center #:width 20)
        (pad   (button #:label "ok" #:action 'save) #:left 2)
        (width (chat-input app) 40)))
```

The cascade reaches every embedded widget regardless of depth or
container kind.  Each widget's `update` returns `(cons next-self
cmd-or-#f)`; the engine threads `next-self` back into the parent
slot so the next render sees the new state.  Widgets that don't
care about a given msg fall through the default catch-all and
return `(cons self #f)`.

### Focus

Key and mouse msgs route to the **focus chain**: the path of widgets
from root to the currently focused widget. Default focus is the root
widget. Move focus with the `focus` cmd:

```scheme
(define-method (update (c <chat>) (msg <init>))
  (focus (chat-input c)))               ; <- input gets keys from the first frame
```

Keys and mouse msgs dispatch **leaf-to-root**: the focused widget
fires first, then each ancestor. A `<textinput>` can insert a char
while a `<chat>` above it appends the line on enter; both fire in
order:

```scheme
(define-method (update (c <chat>) (msg <key>))
  (cond
   ((eq? (key-sym msg) 'return)
    (let ((val (textinput-value (chat-input c))))
      (cond
       ((zero? (string-length val)) (cons c #f))
       (else
        (cons (update-slots c
                #:lines (cons val (chat-lines c))
                #:input (update-slots (chat-input c)
                          #:value "" #:cursor 0))
              #f)))))
   (else (cons c #f))))
```

Every widget in the focus chain fires for every key/mouse msg, in
leaf-to-root order.  Because the leaf fires first, an ancestor sees
the child's already-updated state when its own `update` runs.  The
chat above can read `textinput-value` on Enter and get exactly what
the user typed — the textinput already handled the keystrokes that
built that buffer.

Non-key/mouse msgs (`<init>`, `<tick>`, `<resize>`, `<paste>`,
`<mount>`, `<unmount>`, focus/blur, keymap-mapped actions like
`'save`, `on-click` action symbols, user msgs sent via `send`)
**broadcast** through the whole tree. Widgets dispatch on the msg
class. Any widget that specialises `update` on `<paste>` receives the
payload via `paste-text`.

### Widget lifecycle

A widget gets `<mount>` when it appears in the view tree, `<unmount>`
when it leaves. `<init>` fires once per app at startup.

```scheme
(define-method (update (s <spinner>) (msg <mount>))
  (every #:hz 10 #:id (list 'spinner-tick s) (lambda () (tick))))

;; no <unmount> method needed -- the global catch-all returns
;; nothing, and the engine auto-cancels the sub because it was
;; installed while this widget was the current dispatch target.
```

`every` and `after` cmds installed during a widget's `update` are
tagged with that widget. Removing the widget from the view cancels
the sub.

Subscriptions without `#:id` live until the engine stops; they can't
be cancelled. Re-issuing the same `(every #:id k ...)` is idempotent:
the engine spawns once. The id is any `eq?`-comparable value: a
symbol, a widget, a `(list 'tick widget)` pair for per-widget ids.

## Live coding

The engine keeps running across edits. Connect a REPL to a running
app and re-evaluate any form:

- Re-evaluating a `(define-method (view ...) ...)` form replaces the
  method body; the next render uses it.
- Re-evaluating a `(define-class ...)` form runs Guile's class-
  redefinition protocol; existing widgets migrate to the new slot
  layout.
- Edit a `view` or `update` method, save, re-evaluate the form
  from a Geiser-aware editor.  Method redefinition replaces the
  prior body against the running image; the next render uses it.
- Re-evaluating a theme swaps palettes or restyles.

`make repl` runs `guile -L . --listen=37147`, opening a TCP REPL on
port 37147. Connect with `telnet localhost 37147`, or from any editor
that talks to a Guile REPL.

## Msgs

Engine-emitted records matched in `update`.

| record     | when                                          |
|------------|-----------------------------------------------|
| `<key>`    | a keystroke (with optional modifiers)         |
| `<mouse>`  | mouse button / motion / scroll                |
| `<tick>`   | an `every` or `after` cmd fired               |
| `<resize>` | terminal size changed (debounced ~50 ms)      |
| `<init>`   | once before the first user input              |
| `<mount>`  | a widget just appeared in the view tree       |
| `<unmount>`| a widget just left the view tree              |
| `<paste>`  | a bracketed-paste payload (`paste-text` for the raw string) |
| `<focus>`  | terminal gained focus (msg ctor: `(focused)`) |
| `<blur>`   | terminal lost focus  (msg ctor: `(blurred)`)  |
| `<resume>` | engine reacquired tty after suspend           |
| symbol     | keymap action; `on-click` action; user msg    |
| list       | any user-defined shape via `(send eng ...)`     |

Multi-method dispatch on the msg class is the natural shape.  One
method per msg class you care about; everything else falls through to
the global catch-all in `(canary view)`, so you don't write a per-
class catch-all.

```scheme
(define-method (update (c <my>) (msg <tick>)) ...)
(define-method (update (c <my>) (msg <key>))  ...)
;; no per-class catch-all; non-matching msgs are silently no-op
```

## Cmds

Returned from `update` (second value). Cmds are constructor calls,
not quoted literals.

| cmd                                 | effect                                  |
|-------------------------------------|-----------------------------------------|
| `#f`                                | no-op                                   |
| `'quit`                             | exit `run-app`                          |
| `(batch c1 c2 ...)`                   | parallel                                |
| `(sequence c1 c2 ...)`                | sequential, awaits each                 |
| `(every #:hz N [#:id k] producer)`  | persistent ticker: one fiber; cancel with `(cancel k)` |
| `(every #:ms N [#:id k] producer)`  | same                                    |
| `(after #:ms N [#:id k] producer)`  | one-shot timer; cancel with `(cancel k)` before it fires |
| `(cancel id)`                       | stop a sub installed with that `#:id`   |
| `(println "string" ...)`              | line to scrollback above alt-screen     |
| `(set-title "name")`                | runtime OS title change                 |
| `(clear-screen)`                    | force full repaint                      |
| `(cursor 'hidden|'visible|'bar|...)`  | runtime cursor change                   |
| `(alt-screen 'on|'off)`             | runtime alt-screen toggle               |
| `(mouse-mode 'off|'click|'cell|'all)` | runtime mouse mode change             |
| `(set-palette 'name)`               | switch active palette                   |
| `(cycle-palette)`                   | next palette in theme's declared order  |
| `(suspend)`                         | hand tty to shell, resume on SIGCONT    |
| `(exec "cmd args" #:on-done thunk)` | tear down, run process, restore, msg    |
| `(focus widget)`                    | route key/mouse msgs to this widget chain |
| user thunk                          | engine spawns fiber; thunk returns msg  |

## Click & hover

```scheme
(on-click body #:action act #:right right-act)
(on-hover body styler-proc)
```

`on-click` wraps any body so a left-press inside its rendered area
dispatches `#:action` as a msg, and a right-press dispatches
`#:right` (optional). `on-hover` swaps `body` for `(styler-proc body)`
whenever the cursor is inside the area; purely visual.

```scheme
(on-click (on-hover (txt " save " #:fg 'muted)
                    (lambda (_) (txt " save " #:fg 'accent #:bold)))
          #:action 'save)
```

## Keys and keymap

```scheme
(keymap
 (bind k1 [k2 ...] action [#:timeout-ms N])
 ...)
```

| form                                    | meaning                    |
|-----------------------------------------|----------------------------|
| `#\h`, `#\?`, `#\:`                     | literal char               |
| `#\tab` `#\escape` `#\space` `#\return` `#\delete` `#\backspace` | named chars |
| `'left` `'right` `'up` `'down` `'home` `'end` `'pgup` `'pgdn` `'f1`...`'f12` | symbols |
| `'(#\x ctrl)` `'(left ctrl)`            | modifier list              |
| `'(mouse left)` `'(mouse right)`        | mouse button               |
| `'(mouse-scroll up)` `'(mouse-scroll down)` | scroll wheel           |

Modifiers: `control`/`ctrl`, `alt`/`option`, `shift`,
`super`/`cmd`/`command`, `meta`, `hyper`. Canonicalised, sorted,
deduped internally. `meta` and `hyper` are distinct mods (they match
the kitty keyboard protocol's bit-field positions); `meta` is no
longer an alias for `alt`.

```scheme
(bind #\q 'quit)
(bind 'escape 'cancel)
(bind '(#\x ctrl) 'cut)
(bind #\g #\g 'top #:timeout-ms 500)
(bind '(mouse left) 'select)
```

`'quit` is engine-intercepted. Anything else is dispatched to
`update`.

### Three levels of key handling

| level   | where it lives                                  | use for                                  |
|---------|-------------------------------------------------|-------------------------------------------|
| global  | engine's `keymap` slot (`run-app #:keymap`)      | app-wide binds — quit, `ctrl-c`           |
| scoped  | `with-keymap` wrapper in the view tree           | scene binds, modal overlays, per-pane    |
| raw     | focused widget's `update (msg <key>)` method     | typing, inline nav (textinput, menu)     |

Dispatch order on a key:

1. Engine collects scoped keymaps from `with-keymap` wrappers along
   the focus path AND inside the focused widget's own view (innermost
   wrapper first).
2. Stack walks top-down: scoped innermost → scoped outermost →
   engine global. First match fires its action symbol as a cascade
   msg, and the raw key is consumed.
3. If nothing matches, the raw key routes down the focus chain to
   the focused widget's `update (msg <key>)` method (typing, etc).

Scoped beats raw. Don't bind self-inserting chars (`#\h`, `#\a`, …)
in a scope that contains a focused textinput — the bind shadows the
typed char. Reserve scoped chars for modes where typing isn't
happening (game keys on a canvas) and reserve action keys (`escape`,
`enter`, `tab`, function keys, modifier chords) for scopes that
overlay text inputs.

### Anatomy of a multi-scene app

The shape every non-trivial canary app converges on:

```scheme
;;; Root: holds the active scene, swaps it on <scene-change>.
(define-class <app> (<focusable>)
  (scene #:init-keyword #:scene #:getter app-scene))

(define-method (view (a <app>))
  ;; Return the scene AS a node, NOT (view scene).
  ;; Calling view here renders the scene immediately, stripping its
  ;; widget identity from the tree — focus can no longer reach it,
  ;; and any `with-keymap` the scene wraps itself with goes silent.
  (app-scene a))

(define-method (update (a <app>) (msg <scene-change>))
  (cons (update-slots a #:scene (scene-change-scene msg)) #f))

;;; Each scene owns its keymap and wraps its own view.
(define-class <auth> (<focusable>)
  (menu #:init-form (menu #:items %auth-items) #:getter auth-menu))

(define %auth-km
  (keymap (bind 'escape 'auth-back)))

(define-method (view (a <auth>))
  (with-keymap %auth-km
    (vbox (title-view) (auth-menu a))))

(define-method (update (a <auth>) (msg <mount>))
  ;; Send raw keys to the menu (its update handles arrows/enter).
  (cons a (focus (auth-menu a))))

;;; Canvas scene: own keymap, optional modal overlay.
(define %canvas-km
  (keymap (bind #\h 'move-left) (bind 'escape 'open-pause)))

(define %pause-km
  (keymap (bind 'escape 'close-pause) (bind 'enter 'menu-select)))

(define-class <canvas> (<focusable>)
  (pause-menu #:init-value #f #:getter canvas-pause-menu))

(define-method (view (c <canvas>))
  (with-keymap (if (canvas-pause-menu c) %pause-km %canvas-km)
    (vbox (map-view c)
          (and (canvas-pause-menu c) (canvas-pause-menu c)))))
```

When the pause menu opens and gets focused, the active stack is
`[%pause-km, engine-global]`. `escape` matches `%pause-km` first and
fires `'close-pause`. When the menu closes (slot cleared, focus
back on canvas), the canvas's `view` swaps in `%canvas-km` and the
stack reshapes — no push/pop bookkeeping. The wrapper vanishing
from the tree is what de-scopes it.

Three things are non-obvious the first time you build this shape:

- **Parent returns child as a node.** `(view (app-scene a))` is
  wrong; `(app-scene a)` is right. The engine walks through child
  widgets and re-enters their `view` itself.

- **Scene wraps its own view in `with-keymap`.** Don't put scoped
  binds on the parent — they should travel with the scene.

- **Use `focus` to route raw keys to one of N coexisting children.**
  Cascade walks every focusable slot on the parent for non-key msgs,
  but raw keys go through the focus chain alone. If a parent has
  three textinputs in slots and you don't focus one, all three
  receive every keystroke.

### Chord-state caveat

Scoped keymaps don't preserve multi-key chord state across renders
(the wrapper is rebuilt per frame). Define chord-bearing keymaps as
the engine global, where chord state is held on `<engine>` and
survives between dispatches.

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

- `#:fg` / `#:bg`: hex string (`"#abc123"`) or palette name (`'accent`)
- `#:bold` `#:italic` `#:underline` `#:reverse` `#:strike` `#:dim`:
  individual boolean flags.

Containers:

```scheme
(vbox a b c)
(hbox a b c)
(spacer n)                                ; height in vbox
(spacer #:w n)                            ; width  in hbox
(pad    body  #:top n #:left n ...)         ; inner whitespace
(margin body  #:top n #:left n ...)         ; outer whitespace
(align  body  #:h 'left|'center|'right #:v 'top|'middle|'bottom
              #:width n #:height n)        ; positions body within its rect
(width  body  n)
(height body  n #:valign 'top|'center|'bottom)
(fill   w h #:bg 'name-or-hex)
(pin    col row body)
(overlay base p1 p2 ...)
(boxed  body  #:border border-rounded #:fg 'name #:title "name")
(static body)                            ; cache rendered cmds keyed on rect
(on-click body #:action a #:right ra)
(on-hover body styler-proc)
(link "https://..." body)                ; OSC 8 clickable hyperlink
(prompt-zone body)                       ; OSC 133 ; A  - shell prompt
(input-zone  body)                       ; OSC 133 ; B  - typed command
(output-zone body)                       ; OSC 133 ; C  - command output
(flex    body  #:grow 1 #:shrink 0)
(wrap    "long text" #:fg 'name #:bold)   ; word-wraps to its rect's width
```

`pad` and `margin` are distinct: `pad` adds space *inside* a
boxed/styled region, `margin` adds space *outside*.

`link` and the `*-zone` wrappers tag their body's cells with
metadata the diff emitter forwards as OSC 8 or OSC 133.  Modern
host terminals make `link` cells clickable and use zone tags for
shell-integration features.  Older hosts strip the escape sequences
and render the body unchanged.

### Align

`align` positions a node within the rect it's been given. Modes on
each axis are kwargs:

- `#:h` — `'left` (default), `'center`, `'right`
- `#:v` — `'top` (default), `'middle`, `'bottom`

`#:width` / `#:height` pin the alignment slot explicitly; otherwise
it inherits the rect's full dimension on that axis.

When the node overflows the slot, the anchored edge stays inside
the rect and the opposite edge clips. `(align body #:v 'bottom)`
with a vbox of 1000 lines in a 24-row rect shows the last 24 lines;
the top of the vbox renders off the rect and the term grid drops
out-of-range writes. Same on the horizontal axis with `#:h 'right`.
Use this for chat-style tail-anchoring, right-aligned status, or
centered-overflow content.

```scheme
(align (vbox banner subtitle ...) #:h 'center #:v 'middle)   ; splash
(align history-vbox #:v 'bottom)                            ; chat tail
(align timestamp #:h 'right)                                ; status
```

### Flex

`flex` tags an item inside a vbox or hbox as flexible. The box first
sums every item's intrinsic size along its major axis (height for
vbox, width for hbox). Any surplus is shared among flex items by
their `#:grow` shares; any deficit is shared by `#:shrink`. Items
without `flex` keep their intrinsic size; `flex` outside a vbox/hbox
is transparent.

```scheme
(vbox (txt "top bar")
      (flex middle)                       ; absorbs leftover height
      (txt "bottom bar"))

(hbox sidebar
      (flex canvas #:grow 1)
      (flex preview #:grow 2))            ; canvas 1/3, preview 2/3
```

Defaults: `#:grow 1 #:shrink 0` -> "take any extra, don't shrink past
intrinsic". A bare `(flex x)` is the common case.

Don't subtract terminal dimensions to size items by hand
(`(width body (- cols 10))`). Wrap with `flex` and the box does the
math, even across resizes.

### Wrap

`wrap` is a word-wrapping text node. Unlike `txt` (single-line, clips
on overflow), `wrap` re-flows its string to the rendered rect's width
on each frame. Newlines in the input become paragraph breaks.

```scheme
(flex (wrap "Long preview text that re-flows when the pane resizes..."
            #:fg 'muted))
```

`wrap` reports intrinsic `(1, 1)`: it's a fill widget. Outside a
`flex` it shrinks to one cell. The author decides how much room to
give it by wrapping in `flex` (or `(width ...)` / `(height ...)`).

## Bundled components

Plain widget classes in `canary/components/`:

- `<button>`: title + on-click
- `<panel>`: title + border + footer + content, with hover affordance
- `<textinput>`: single-line input with cursor
- `<spinner>`: animated frames, installs its own ticker on `<mount>`
- `<progress>`: bar with percentage
- `<paginator>`: page indicator with key bindings
- `<viewport>`: scrollable list of items with optional tail-mode auto-follow

Each exposes a bare-named constructor (`(button #:label ...)`,
`(spinner)`, `(textinput #:prompt ...)`, etc.) and a small set of
`X-field` accessors.  Embed a widget as a slot on your app class;
the engine cascades msgs into it automatically.

Naming is uniform across the whole library: `<thing>` is the class
or record type, `thing` is the constructor, `thing?` is the
predicate, `thing-field` is the accessor.  No `make-` prefix on any
user-facing constructor. Applies to engine plumbing (`(engine
#:backend ...)`, `(ansi-backend #:port ...)`) and spring helpers
(`(spring-animation ...)`, `(spring-bouncy)`) too.

## Anti-patterns

- **Don't** mutate slots with `set!` from inside `update`.  Build the
  next state with `update-slots` and return it paired with the cmd.
- **Don't** wrap the pair in `(values ...)`.  The return is one
  ordinary pair: `(cons next-self cmd-or-#f)`.
- **Don't** quote cmd literals: write `(set-title "x")`, not
  `'(set-title "x")`.
- **Don't** put style flags in a list: write `#:bold #:italic`, not
  `#:attrs '(bold italic)`.
- **Don't** side-effect inside `view`. The cascade walker calls it
  once to find widgets before render calls it again to produce cmds;
  any effect fires twice per msg.
- **Don't** expand widgets via `(view (chat-input c))` in your own
  view; pass the widget itself, `(chat-input c)`. The cascade can't
  reach widgets it can't see by reference.

## Backend, grid, parser

Rendering routes through a cell grid.  The backend (`<ansi-backend>`)
keeps two `<term>` records as private state: `cur-term` and
`prev-term`.  Each frame:

1. The engine asks the renderer for draw cmds against the current
   widget tree.
2. The backend replays those cmds into `cur-term`, mutating cells
   one at a time (`render-cmds-to-term!`).
3. `term-diff->ansi prev-term cur-term` emits the minimal ANSI byte
   sequence that takes a host terminal displaying `prev-term` to
   one displaying `cur-term`: cursor moves, SGR changes, OSC 8 / OSC
   133 transitions, then the changed glyphs.
4. The backend swaps the slots so the next frame diffs against this
   one.

`<term>` is therefore both the model the emulator parses into *and*
the model canary's own rendering writes into.  Two doors into the
same data structure:

- write path: tree → draw cmds → cells, used every frame
- parse path: bytes → `term-process-output!` → cells, used by tests,
  snapshot tools, and any consumer that wants to feed a `<term>` an
  external byte stream

One door out: `term-diff->ansi` → host bytes.

Cells carry codepoint, face attributes (fg, bg, bold, italic,
underline style, underline colour, overline, blink, inverse,
conceal, strike), hyperlink uri, and semantic-content tag.  Adding a
new cell attribute means extending `<face-attrs>` once; both the
write path and the parse path pick it up.

The emulator pieces live in `(canary term ...)` and re-export
together as `(canary term)`.  Useful entry points:

- `make-term`, `term-process-output!`, `term-process-bytes!`
- `view->grid` to render a view tree into a fresh `<term>`
- `term->text-snapshot`, `term->ansi-snapshot` for golden-file tests
- `replay-ansi` to parse a recorded byte stream
- `mode-get` / `mode-set!` for the 38-mode VT state table
- `update` specialised on `<op-set-mode>` / `<op-reset-mode>` (and
  other op records) intercepts emulator decisions live from the REPL

## Terminal capabilities

`backend-init` enables the following terminal modes; `backend-shutdown`
restores them in reverse order:

| escape         | mode                                              |
|----------------|---------------------------------------------------|
| `\e[?1049h`    | alternate screen buffer                           |
| `\e[?25l`      | hide cursor                                       |
| `\e[?1004h`    | focus reporting (`<focus>` / `<blur>`)            |
| `\e[?2004h`    | bracketed paste (`<paste>` with `paste-text`)     |
| `\e[>5u`       | kitty keyboard protocol, flags 1+4 (disambiguate + alternate keys) |

Each frame's cell diff is bracketed by `\e[?2026h` ... `\e[?2026l`
(synchronized output), so terminals that honour it never paint a
half-written frame.

Mouse reporting is opt-in via the `#:mouse` kwarg on `run-app`
(`'click`/`'cell`/`'all`). Kitty-graphics image support is detected
at init via a capability probe; falls back to text fallback views
when the terminal doesn't speak the protocol.

