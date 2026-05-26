(define-module (canary layout)
  #:use-module (canary view)
  #:use-module (canary faces)
  #:use-module (srfi srfi-1)
  #:export (txt
            vbox
            hbox
            spacer
            join
            pad
            margin
            align
            width
            height
            fill
            place-cursor
            pin
            overlay
            static
            image
            on-click
            on-hover
            link
            prompt-zone
            input-zone
            output-zone
            flex
            wrap
            parse-style-args))

(define %empty-text (make-text-node "" 'default '()))

(define (parse-style-args args)
  "Parse a mixed arg list. Returns (values positionals face attrs).
Recognised kwargs (each consumed in place):
  #:fg c / #:bg c   — c is a hex string \"#abc123\" or a palette symbol
  #:bold #:italic #:underline #:reverse #:strike #:dim
FACE is #f if neither #:fg nor #:bg was supplied."
  (let lp ((args args)
           (pos '())
           (fg #f) (bg #f) (has-color? #f)
           (attrs '()))
    (cond
     ((null? args)
      (values (reverse pos)
              (if has-color? (face #:fg fg #:bg bg #:attrs '()) #f)
              (reverse attrs)))
     ((eq? (car args) #:fg)
      (lp (cddr args) pos (cadr args) bg #t attrs))
     ((eq? (car args) #:bg)
      (lp (cddr args) pos fg (cadr args) #t attrs))
     ((eq? (car args) #:bold)      (lp (cdr args) pos fg bg has-color? (cons 'bold attrs)))
     ((eq? (car args) #:italic)    (lp (cdr args) pos fg bg has-color? (cons 'italic attrs)))
     ((eq? (car args) #:underline) (lp (cdr args) pos fg bg has-color? (cons 'underline attrs)))
     ((eq? (car args) #:reverse)   (lp (cdr args) pos fg bg has-color? (cons 'reverse attrs)))
     ((eq? (car args) #:strike)    (lp (cdr args) pos fg bg has-color? (cons 'strikethrough attrs)))
     ((eq? (car args) #:dim)       (lp (cdr args) pos fg bg has-color? (cons 'dim attrs)))
     (else
      (lp (cdr args) (cons (car args) pos) fg bg has-color? attrs)))))

(define (txt . args)
  "Build a text node.
Positional args are strings or nested text nodes (inline spans).
Styling kwargs: #:fg #:bg (hex or palette symbol),
                #:bold #:italic #:underline #:reverse #:strike #:dim."
  (call-with-values (lambda () (parse-style-args args))
    (lambda (spans eff-face rev-attrs)
      (cond
       ((null? spans)
        (if (and (not eff-face) (null? rev-attrs))
            %empty-text
            (make-text-node "" (or eff-face 'default) rev-attrs)))
       ((and (null? (cdr spans)) (string? (car spans)))
        (if (and (string-null? (car spans))
                 (not eff-face) (null? rev-attrs))
            %empty-text
            (make-text-node (car spans) (or eff-face 'default) rev-attrs)))
       (else
        (make-text-runs-node
         (map (lambda (s)
                (cond
                 ((string? s)
                  (make-text-node s (or eff-face 'default) rev-attrs))
                 (else s)))
              spans)))))))

(define (vbox . args)
  "Build a vertical box stacking its items top to bottom.  ARGS
is a mix of body nodes and the styling kwargs accepted by `txt`.
#f items are filtered out so callers can pass conditional slots."
  (call-with-values (lambda () (parse-style-args args))
    (lambda (items face _attrs)
      (make-vbox-node (filter (lambda (x) x) items) face))))

(define (hbox . args)
  "Build a horizontal box laying its items left to right.  ARGS
is a mix of body nodes and the styling kwargs accepted by `txt`.
#f items are filtered out so callers can pass conditional slots."
  (call-with-values (lambda () (parse-style-args args))
    (lambda (items face _attrs)
      (make-hbox-node (filter (lambda (x) x) items) face))))

(define %zero-spacer (make-spacer-node 0 0))

(define* (spacer #:optional (n #f) #:key (w 0) (h 0))
  "Build an empty space node.  With one positional arg N, expands to
N cells along the box's major axis.  Otherwise sized explicitly by
#:w / #:h.  A zero-sized spacer is shared (no allocation)."
  (cond
   ((and (not n) (zero? w) (zero? h)) %zero-spacer)
   ((not n) (make-spacer-node w h))
   ((eqv? n 0) %zero-spacer)
   (else (make-spacer-node w n))))

(define (static body)
  "Wrap BODY so the engine skips its update generic.  Use for nodes
that never react to messages — saves a generic dispatch per tick."
  (make-static-node body))

(define (join . elements)
  "Stack ELEMENTS vertically.  Convenience alias for vbox without
styling kwargs."
  (apply vbox elements))

(define* (pad body #:key (top 0) (right 0) (bottom 0) (left 0) (all 0)
              (fg #f) (bg #f))
  "Wrap BODY with padding cells inside its border.  Specify per-side
amounts (#:top / #:right / #:bottom / #:left) or #:all for uniform
padding.  #:fg / #:bg apply a face to the padding cells."
  (let ((t (if (positive? all) all top))
        (r (if (positive? all) all right))
        (b (if (positive? all) all bottom))
        (l (if (positive? all) all left))
        (f (if (or fg bg) (face #:fg fg #:bg bg #:attrs '()) #f)))
    (make-pad-node body t r b l f)))

(define* (margin body #:key (top 0) (right 0) (bottom 0) (left 0) (all 0))
  "Wrap BODY with empty margin cells outside its border.  Like pad
but the margin cells are transparent (no face), so the parent
background shows through."
  (let ((t (if (positive? all) all top))
        (r (if (positive? all) all right))
        (b (if (positive? all) all bottom))
        (l (if (positive? all) all left)))
    (make-margin-node body t r b l)))

(define* (align body #:key (h 'left) (v 'top) (width #f) (height #f))
  "Position BODY inside the rect.

#:h — 'left (default), 'center, 'right.
#:v — 'top  (default), 'middle, 'bottom.

#:width / #:height pin the alignment slot explicitly; otherwise the
slot inherits the parent rect's full dimension on that axis.

Overflow rule: when BODY's intrinsic size exceeds the alignment
slot on an axis, the anchored edge stays inside the slot and the
opposite edge clips.  E.g. `#:v 'bottom` with overflowing content
clips from the top — natural for chat-style tail anchoring."
  (case h ((left center right) #t) (else (error "align: bad #:h" h)))
  (case v ((top middle bottom) #t) (else (error "align: bad #:v" v)))
  (make-align-node body h v width height))

(define* (width body w #:key (align 'left))
  "Constrain BODY to W cells wide.  #:align controls placement
within the slot when BODY is narrower than W ('left, 'center,
'right)."
  (make-width-node body w align))

(define* (height body h #:key (valign 'top))
  "Constrain BODY to H cells tall.  #:valign controls placement
within the slot when BODY is shorter than H ('top, 'middle,
'bottom)."
  (make-height-node body h valign))

(define* (fill w h #:key (fg #f) (bg #f))
  "Build a solid-color block W cells wide by H cells tall.  Default
face is 'default; supply #:fg / #:bg to colour it."
  (let ((f (cond
            ((or fg bg) (face #:fg fg #:bg bg #:attrs '()))
            (else 'default))))
    (make-fill-node w h f)))

(define* (place-cursor col row #:key (style 'block))
  "Emit a cursor-placement node at (COL, ROW).  #:style is the
cursor shape: 'block, 'underline, or 'bar.  Only the last cursor
node in render order takes effect."
  (make-cursor-node col row style))

(define (pin col row body)
  "Position BODY at absolute (COL, ROW) within an overlay.  Use
inside `overlay` to layer floating elements over a base view."
  (make-placement col row body))

(define (overlay base . pins)
  "Render BASE with each PIN (a `pin` node) drawn on top in order.
Pins are clipped to BASE's rect."
  (make-overlay-node base pins))

(define* (image src #:key (w 1) (h 1) (px 0) (py 0)
                (src-x 0) (src-y 0) (src-w 0) (src-h 0)
                (fallback #f))
  "Build an image-placement node referencing registered image SRC.
#:w / #:h size the cell footprint; #:px / #:py shift the image
within its cell in pixels; #:src-x / #:src-y / #:src-w / #:src-h
crop the source image; #:fallback is the view to render when the
terminal lacks graphics support (defaults to a blank spacer)."
  (make-image-node src w h px py src-x src-y src-w src-h
                   (or fallback (make-spacer-node w h))))

(define* (on-click body #:key action right)
  "Wrap BODY so mouse presses inside its rendered rect dispatch as
msgs through update.  Left-press dispatches #:ACTION; right-press
dispatches #:RIGHT.  Either may be #f.  Each action is any value the
app's update knows how to match (symbol, list, key)."
  (make-click-node action body right))

(define (link uri body)
  "Wrap BODY as an OSC 8 hyperlink to URI.  Cells rendered for BODY
carry URI as their hyperlink so capable host terminals
(kitty, foot, wezterm, vte-based) render them as clickable links."
  (make-link-node uri body))

(define (prompt-zone body)
  "Tag BODY's cells as a shell prompt (OSC 133 ; A).  Capable host
terminals use this to mark per-command anchors for navigation and
selection."
  (make-semantic-node 'prompt body))

(define (input-zone body)
  "Tag BODY's cells as command-line input (OSC 133 ; B)."
  (make-semantic-node 'input body))

(define (output-zone body)
  "Tag BODY's cells as command output (OSC 133 ; C)."
  (make-semantic-node 'output body))

(define (on-hover body styler)
  "Wrap BODY so the engine renders STYLER's output instead while the
mouse cursor is inside the body's rect. STYLER is a unary procedure
(lambda (body) → view-node) — return whatever view should replace the
body on hover. For a static substitute, use (lambda (_) replacement)."
  (make-hover-node body styler))

(define* (flex body #:key (grow 1) (shrink 0))
  "Tag BODY as flexible inside a vbox or hbox. After the box sums its
items' intrinsic sizes, surplus along the major axis is shared by
GROW; deficit by SHRINK. Defaults: grow=1, shrink=0 → 'take any
extra; don't shrink past intrinsic'. Outside a vbox/hbox the wrapper
is transparent and BODY renders at its intrinsic size."
  (unless (and (number? grow)   (>= grow 0))
    (error "flex: GROW must be a non-negative number" grow))
  (unless (and (number? shrink) (>= shrink 0))
    (error "flex: SHRINK must be a non-negative number" shrink))
  (make-flex-node body grow shrink))

(define (wrap str . styling-args)
  "Word-wrapped text. STR is wrapped to the rendered rect's width on
each render; newlines in STR are paragraph breaks. Styling kwargs
match `txt`: #:fg #:bg (hex string or palette symbol), and the boolean
flags #:bold #:italic #:underline #:reverse #:strike #:dim.

`wrap` reports intrinsic size (1,1) so it behaves as a fill widget
inside a vbox/hbox — wrap it in `flex` to claim space:

  (flex (wrap long-text))

Outside flex it shrinks to one cell. That is intentional: the wrap
height depends on the rect width, so the parent container has to
decide how much room to give it."
  (call-with-values (lambda () (parse-style-args styling-args))
    (lambda (_ face attrs)
      (make-wrap-node str (or face 'default) attrs))))
