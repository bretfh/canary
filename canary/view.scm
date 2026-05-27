(define-module (canary view)
  #:use-module (canary width)
  #:use-module (srfi srfi-9)
  #:use-module (oop goops)
  #:export (view update
            with-view-cache memoized-view invalidate-cached-view!
            <rect>
            rect?
            make-rect
            rect-col
            rect-row
            rect-w
            rect-h
            rect-empty?
            rect=?

            view-node?
            view-size
            invalidate-size!

            <text-node>
            text-node?
            make-text-node
            text-node-str
            text-node-face
            text-node-attrs

            <text-runs-node>
            text-runs-node?
            make-text-runs-node
            text-runs-node-runs

            <fill-node>
            fill-node?
            make-fill-node
            fill-node-w
            fill-node-h
            fill-node-face

            <spacer-node>
            spacer-node?
            make-spacer-node
            spacer-node-w
            spacer-node-h

            <vbox-node>
            vbox-node?
            make-vbox-node
            vbox-node-items
            vbox-node-face

            <hbox-node>
            hbox-node?
            make-hbox-node
            hbox-node-items
            hbox-node-face

            <boxed-node>
            boxed-node?
            make-boxed-node
            boxed-node-body
            boxed-node-border
            boxed-node-face
            boxed-node-title

            <pad-node>
            pad-node?
            make-pad-node
            pad-node-body
            pad-node-top
            pad-node-right
            pad-node-bottom
            pad-node-left
            pad-node-face

            <margin-node>
            margin-node?
            make-margin-node
            margin-node-body
            margin-node-top
            margin-node-right
            margin-node-bottom
            margin-node-left

            <align-node>
            align-node?
            make-align-node
            align-node-body
            align-node-h
            align-node-v
            align-node-width
            align-node-height

            <width-node>
            width-node?
            make-width-node
            width-node-body
            width-node-w
            width-node-align

            <height-node>
            height-node?
            make-height-node
            height-node-body
            height-node-h
            height-node-valign

            <cursor-node>
            cursor-node?
            make-cursor-node
            cursor-node-col
            cursor-node-row
            cursor-node-style

            <overlay-node>
            overlay-node?
            make-overlay-node
            overlay-node-base
            overlay-node-overlays

            <placement>
            placement?
            make-placement
            placement-col
            placement-row
            placement-body

            <static-node>
            static-node?
            make-static-node
            static-node-body
            static-node-cached-rect
            set-static-node-cached-rect!
            static-node-cached-cmds
            set-static-node-cached-cmds!

            <image-node>
            image-node?
            make-image-node
            image-node-src
            image-node-w
            image-node-h
            image-node-px
            image-node-py
            image-node-src-x
            image-node-src-y
            image-node-src-w
            image-node-src-h
            image-node-fallback

            <click-node>
            click-node?
            make-click-node
            click-node-action
            click-node-right-action
            click-node-body

            <link-node>
            link-node?
            make-link-node
            link-node-uri
            link-node-body

            <semantic-node>
            semantic-node?
            make-semantic-node
            semantic-node-kind
            semantic-node-body

            <hover-node>
            hover-node?
            make-hover-node
            hover-node-body
            hover-node-styler

            <flex-node>
            flex-node?
            make-flex-node
            flex-node-body
            flex-node-grow
            flex-node-shrink

            <wrap-node>
            wrap-node?
            make-wrap-node
            wrap-node-str
            wrap-node-face
            wrap-node-attrs))

(define-record-type <rect>
  (make-rect col row w h)
  rect?
  (col rect-col)
  (row rect-row)
  (w rect-w)
  (h rect-h))

(define (rect-empty? r)
  "Return #t if R has zero or negative width or height."
  (or (<= (rect-w r) 0) (<= (rect-h r) 0)))

(define (rect=? a b)
  "Return #t if rectangles A and B have identical origin and size."
  (and (= (rect-col a) (rect-col b))
       (= (rect-row a) (rect-row b))
       (= (rect-w   a) (rect-w   b))
       (= (rect-h   a) (rect-h   b))))

(define-record-type <text-node>
  (%text-node str face attrs cache)
  text-node?
  (str text-node-str)
  (face text-node-face)
  (attrs text-node-attrs)
  (cache text-node-cache set-text-node-cache!))

(define (make-text-node str face attrs)
  "Return a fresh <text-node> holding string STR rendered under FACE
with extra ATTRS (a list of attribute symbols).  The size cache
starts empty."
  (%text-node str face attrs #f))

(define-record-type <text-runs-node>
  (%text-runs-node runs cache) text-runs-node?
  (runs  text-runs-node-runs)
  (cache text-runs-node-cache set-text-runs-node-cache!))

(define (make-text-runs-node runs)
  "Return a fresh <text-runs-node> sequencing RUNS (a list of
<text-node>s or strings) inline on a single line."
  (%text-runs-node runs #f))

(define-record-type <fill-node>
  (%fill-node w h face cache)
  fill-node?
  (w fill-node-w)
  (h fill-node-h)
  (face fill-node-face)
  (cache fill-node-cache set-fill-node-cache!))

(define (make-fill-node w h face)
  "Return a fresh <fill-node> of W cells by H cells painted with
FACE."
  (%fill-node w h face #f))

(define-record-type <spacer-node>
  (%spacer-node w h cache)
  spacer-node?
  (w spacer-node-w)
  (h spacer-node-h)
  (cache spacer-node-cache set-spacer-node-cache!))

(define (make-spacer-node w h)
  "Return a fresh <spacer-node> reserving W cells by H cells of
empty space."
  (%spacer-node w h #f))

(define-record-type <vbox-node>
  (%vbox-node items face cache)
  vbox-node?
  (items vbox-node-items)
  (face vbox-node-face)
  (cache vbox-node-cache set-vbox-node-cache!))

(define (make-vbox-node items face)
  "Return a fresh <vbox-node> stacking ITEMS top to bottom, with
optional FACE applied to the box's background."
  (%vbox-node items face #f))

(define-record-type <hbox-node>
  (%hbox-node items face cache)
  hbox-node?
  (items hbox-node-items)
  (face hbox-node-face)
  (cache hbox-node-cache set-hbox-node-cache!))

(define (make-hbox-node items face)
  "Return a fresh <hbox-node> laying ITEMS left to right, with
optional FACE applied to the box's background."
  (%hbox-node items face #f))

(define-record-type <boxed-node>
  (%boxed-node body border face title cache)
  boxed-node?
  (body boxed-node-body)
  (border boxed-node-border)
  (face boxed-node-face)
  (title boxed-node-title)
  (cache boxed-node-cache set-boxed-node-cache!))

(define* (make-boxed-node body border face #:optional (title #f))
  "Return a fresh <boxed-node> framing BODY with BORDER drawn in
FACE.  Optional TITLE renders inline on the top border."
  (%boxed-node body border face title #f))

(define-record-type <pad-node>
  (%pad-node body top right bottom left face cache)
  pad-node?
  (body pad-node-body)
  (top pad-node-top)
  (right pad-node-right)
  (bottom pad-node-bottom)
  (left pad-node-left)
  (face pad-node-face)
  (cache pad-node-cache set-pad-node-cache!))

(define (make-pad-node body top right bottom left face)
  "Return a fresh <pad-node> wrapping BODY with the given padding
cells on each side, optionally coloured by FACE."
  (%pad-node body top right bottom left face #f))

(define-record-type <margin-node>
  (%margin-node body top right bottom left cache)
  margin-node?
  (body  margin-node-body)
  (top    margin-node-top)
  (right  margin-node-right)
  (bottom margin-node-bottom)
  (left   margin-node-left)
  (cache  margin-node-cache set-margin-node-cache!))

(define (make-margin-node body top right bottom left)
  "Return a fresh <margin-node> wrapping BODY with transparent
margin cells on each side."
  (%margin-node body top right bottom left #f))

(define-record-type <align-node>
  (%align-node body h v width height cache)
  align-node?
  (body  align-node-body)
  (h      align-node-h)
  (v      align-node-v)
  (width  align-node-width)
  (height align-node-height)
  (cache  align-node-cache set-align-node-cache!))

(define (make-align-node body h v width height)
  "Return a fresh <align-node> positioning BODY within its rect.
H is 'left / 'center / 'right; V is 'top / 'middle / 'bottom.
WIDTH and HEIGHT (or #f for the rect's own) cap the slot the body
is positioned inside.  When BODY overflows on an axis, the 'right /
'bottom / 'center / 'middle modes clip from the opposite edge so the
content's anchored edge stays inside the rect."
  (%align-node body h v width height #f))

(define-record-type <width-node>
  (%width-node body w align cache)
  width-node?
  (body width-node-body)
  (w width-node-w)
  (align width-node-align)
  (cache width-node-cache set-width-node-cache!))

(define (make-width-node body w align)
  "Return a fresh <width-node> constraining BODY to W cells wide,
aligning per ALIGN ('left / 'center / 'right) when narrower."
  (%width-node body w align #f))

(define-record-type <height-node>
  (%height-node body h valign cache)
  height-node?
  (body height-node-body)
  (h height-node-h)
  (valign height-node-valign)
  (cache height-node-cache set-height-node-cache!))

(define (make-height-node body h valign)
  "Return a fresh <height-node> constraining BODY to H cells tall,
aligning per VALIGN ('top / 'middle / 'bottom) when shorter."
  (%height-node body h valign #f))

(define-record-type <cursor-node>
  (make-cursor-node col row style)
  cursor-node?
  (col cursor-node-col)
  (row cursor-node-row)
  (style cursor-node-style))

(define-record-type <overlay-node>
  (%overlay-node base overlays cache)
  overlay-node?
  (base overlay-node-base)
  (overlays overlay-node-overlays)
  (cache overlay-node-cache set-overlay-node-cache!))

(define (make-overlay-node base overlays)
  "Return a fresh <overlay-node> rendering BASE with OVERLAYS (a
list of <placement>s) layered on top in order."
  (%overlay-node base overlays #f))

(define-record-type <placement>
  (make-placement col row body)
  placement?
  (col   placement-col)
  (row   placement-row)
  (body placement-body))

(define-record-type <static-node>
  (%static-node body cached-rect cached-cmds size-cache)
  static-node?
  (body static-node-body)
  (cached-rect static-node-cached-rect set-static-node-cached-rect!)
  (cached-cmds static-node-cached-cmds set-static-node-cached-cmds!)
  (size-cache static-node-size-cache set-static-node-size-cache!))

(define (make-static-node body)
  "Return a fresh <static-node> wrapping BODY.  The engine skips
update dispatch on static nodes and caches the rendered cmds across
frames as long as the assigned rect is unchanged."
  (%static-node body #f #f #f))

(define-record-type <image-node>
  (make-image-node src w h px py src-x src-y src-w src-h fallback)
  image-node?
  (src      image-node-src)
  (w        image-node-w)
  (h        image-node-h)
  (px       image-node-px)
  (py       image-node-py)
  (src-x    image-node-src-x)
  (src-y    image-node-src-y)
  (src-w    image-node-src-w)
  (src-h    image-node-src-h)
  (fallback image-node-fallback))

(define-record-type <click-node>
  (%click-node action right-action body cache)
  click-node?
  (action       click-node-action)
  (right-action click-node-right-action)
  (body        click-node-body)
  (cache        click-node-cache set-click-node-cache!))

(define* (make-click-node action body #:optional (right-action #f))
  "Return a fresh <click-node> wrapping BODY.  ACTION is dispatched
when the rendered rect receives a left-button press; the optional
RIGHT-ACTION handles right-button presses."
  (%click-node action right-action body #f))

(define-record-type <link-node>
  (%link-node uri body cache)
  link-node?
  (uri   link-node-uri)
  (body  link-node-body)
  (cache link-node-cache set-link-node-cache!))

(define (make-link-node uri body)
  "Return a fresh <link-node> wrapping BODY as a clickable OSC 8
hyperlink to URI.  Capable host terminals render BODY's cells with
an underline that opens URI on click; others ignore the URI and
render BODY unchanged."
  (%link-node uri body #f))

(define-record-type <semantic-node>
  (%semantic-node kind body cache)
  semantic-node?
  (kind  semantic-node-kind)
  (body  semantic-node-body)
  (cache semantic-node-cache set-semantic-node-cache!))

(define (make-semantic-node kind body)
  "Return a fresh <semantic-node> tagging BODY's cells with KIND
(one of 'prompt / 'input / 'output / 'unknown).  Host terminals
that consume OSC 133 use these tags for shell-integration features
like per-command navigation and 'copy command output'."
  (%semantic-node kind body #f))

(define-record-type <hover-node>
  (%hover-node body styler cache)
  hover-node?
  (body   hover-node-body)
  (styler  hover-node-styler)
  (cache   hover-node-cache set-hover-node-cache!))

(define (make-hover-node body styler)
  "STYLER is a unary procedure (lambda (body) → view-node) that
returns the view to render whenever the cursor is inside the node's
assigned rect. Any view transformation works — restyle the body,
swap glyphs, wrap with overlay, return a static replacement node."
  (unless (procedure? styler)
    (error "make-hover-node: STYLER must be a procedure (lambda (body) → view-node)"
           styler))
  (%hover-node body styler #f))

(define-record-type <flex-node>
  (%flex-node body grow shrink cache)
  flex-node?
  (body   flex-node-body)
  (grow   flex-node-grow)
  (shrink flex-node-shrink)
  (cache  flex-node-cache set-flex-node-cache!))

(define (make-flex-node body grow shrink)
  "Return a fresh <flex-node> wrapping BODY with non-negative GROW
and SHRINK weights.  GROW shares vbox/hbox surplus along the major
axis; SHRINK shares deficit.  Outside a box, BODY renders at its
intrinsic size."
  (%flex-node body grow shrink #f))

(define-record-type <wrap-node>
  (%wrap-node str face attrs)
  wrap-node?
  (str   wrap-node-str)
  (face  wrap-node-face)
  (attrs wrap-node-attrs))

(define (make-wrap-node str face attrs)
  "Return a fresh <wrap-node> for word-wrapped string STR styled
with FACE and ATTRS.  Wrapping happens at render time against the
assigned rect's width."
  (%wrap-node str face attrs))

(define-generic view)
(define-generic update)

(define-method (update node msg)
  "Default update method: no cmd, no state change.  Means nodes that
don't specialise `update` still participate in the cascade without
raising no-applicable-method.")

(define %view-cache (make-parameter #f))

(define (with-view-cache cache thunk)
  "Call THUNK with %view-cache parameterised to CACHE (a hash-table
keyed by node identity).  Used by the engine to memoise view-tree
computation across a single render pass."
  (parameterize ((%view-cache cache)) (thunk)))

(define (memoized-view node)
  "Return the rendered view-tree for NODE, consulting and populating
the current %view-cache when one is in scope.  Without a cache, falls
back to a plain `view` call."
  (let ((cache (%view-cache)))
    (cond
     ((not cache) (view node))
     ((hash-ref cache node) => (lambda (tree) tree))
     (else (let ((tree (view node)))
             (hash-set! cache node tree)
             tree)))))

(define (invalidate-cached-view! node)
  "Drop NODE's cached view tree from the current %view-cache, if
any.  Called when NODE's state has changed and its memoised view is
stale."
  (let ((cache (%view-cache)))
    (when cache (hash-remove! cache node))))

(define (view-node? x)
  "Return #t if X is any kind of view-tree node: a known leaf or
container record, a widget (user-defined widgets), a string
(treated as a text leaf), or #f (empty)."
  (or (text-node? x) (text-runs-node? x)
      (fill-node? x) (spacer-node? x)
      (vbox-node? x) (hbox-node? x) (boxed-node? x)
      (pad-node? x) (margin-node? x) (align-node? x)
      (width-node? x) (height-node? x)
      (cursor-node? x) (overlay-node? x) (static-node? x)
      (image-node? x) (click-node? x) (link-node? x) (semantic-node? x)
      (hover-node? x)
      (flex-node? x)
      (wrap-node? x)
      (is-a? x <object>)
      (string? x) (not x)))

(define (str-visible-length s)
  "Return the on-screen cell width of string S, accounting for
zero-width and wide characters."
  (string-display-width s))

(define-syntax-rule (memo getter setter node expr)
  (or (getter node)
      (let ((v expr)) (setter node v) v)))

(define (compute-size node)
  "Compute NODE's intrinsic (width . height) in cells.  Memoised in
each node's cache slot.  Recursive: container sizes are derived from
their items's sizes.  Strings, #f, and widgets without a
known size return zero or a string-width fallback."
  (cond
   ((not node) (cons 0 0))
   ((string? node) (cons (string-display-width node) 1))
   ((text-node? node)
    (memo text-node-cache set-text-node-cache! node
          (cons (str-visible-length (text-node-str node)) 1)))
   ((text-runs-node? node)
    (memo text-runs-node-cache set-text-runs-node-cache! node
          (let loop ((rs (text-runs-node-runs node)) (sw 0))
            (cond
             ((null? rs) (cons sw 1))
             (else (let ((s (view-size (car rs))))
                     (loop (cdr rs) (+ sw (car s)))))))))
   ((fill-node? node)
    (memo fill-node-cache set-fill-node-cache! node
          (cons (fill-node-w node) (fill-node-h node))))
   ((spacer-node? node)
    (memo spacer-node-cache set-spacer-node-cache! node
          (cons (spacer-node-w node) (spacer-node-h node))))
   ((cursor-node? node) (cons 0 0))
   ((vbox-node? node)
    (memo vbox-node-cache set-vbox-node-cache! node
          (let loop ((cs (vbox-node-items node)) (mw 0) (sh 0))
            (if (null? cs)
                (cons mw sh)
                (let ((s (view-size (car cs))))
                  (loop (cdr cs) (max mw (car s)) (+ sh (cdr s))))))))
   ((hbox-node? node)
    (memo hbox-node-cache set-hbox-node-cache! node
          (let loop ((cs (hbox-node-items node)) (sw 0) (mh 0))
            (if (null? cs)
                (cons sw mh)
                (let ((s (view-size (car cs))))
                  (loop (cdr cs) (+ sw (car s)) (max mh (cdr s))))))))
   ((boxed-node? node)
    (memo boxed-node-cache set-boxed-node-cache! node
          (let ((s (view-size (boxed-node-body node))))
            (cons (+ (car s) 2) (+ (cdr s) 2)))))
   ((pad-node? node)
    (memo pad-node-cache set-pad-node-cache! node
          (let ((s (view-size (pad-node-body node))))
            (cons (+ (car s) (pad-node-left node) (pad-node-right node))
                  (+ (cdr s) (pad-node-top node) (pad-node-bottom node))))))
   ((margin-node? node)
    (memo margin-node-cache set-margin-node-cache! node
          (let ((s (view-size (margin-node-body node))))
            (cons (+ (car s) (margin-node-left node) (margin-node-right node))
                  (+ (cdr s) (margin-node-top  node) (margin-node-bottom node))))))
   ((align-node? node)
    (memo align-node-cache set-align-node-cache! node
          (let ((s (view-size (align-node-body node))))
            (cons (or (align-node-width  node) (car s))
                  (or (align-node-height node) (cdr s))))))
   ((width-node? node)
    (memo width-node-cache set-width-node-cache! node
          (let ((s (view-size (width-node-body node))))
            (cons (width-node-w node) (cdr s)))))
   ((height-node? node)
    (memo height-node-cache set-height-node-cache! node
          (let ((s (view-size (height-node-body node))))
            (cons (car s) (height-node-h node)))))
   ((overlay-node? node)
    (memo overlay-node-cache set-overlay-node-cache! node
          (view-size (overlay-node-base node))))
   ((static-node? node)
    (memo static-node-size-cache set-static-node-size-cache! node
          (view-size (static-node-body node))))
   ((image-node? node)
    (cons (image-node-w node) (image-node-h node)))
   ((click-node? node)
    (memo click-node-cache set-click-node-cache! node
          (view-size (click-node-body node))))
   ((link-node? node)
    (memo link-node-cache set-link-node-cache! node
          (view-size (link-node-body node))))
   ((semantic-node? node)
    (memo semantic-node-cache set-semantic-node-cache! node
          (view-size (semantic-node-body node))))
   ((hover-node? node)
    (memo hover-node-cache set-hover-node-cache! node
          (view-size (hover-node-body node))))
   ((flex-node? node)
    (memo flex-node-cache set-flex-node-cache! node
          (view-size (flex-node-body node))))
   ((wrap-node? node) (cons 1 1))
   ((is-a? node <object>)
    ;; Widgets have intrinsic size = the size of their rendered view
    ;; tree.  Returning (0 . 0) here made every vbox/hbox containing
    ;; a widget allocate 0 cells to it; the widget then rendered into
    ;; an empty rect and produced no cmds.  Materialise the view so
    ;; layout containers can size their slots correctly.
    (view-size (memoized-view node)))
   (else (cons 0 0))))

(define (view-size node)
  "Return NODE's intrinsic size as a cons (WIDTH . HEIGHT)."
  (compute-size node))

(define (invalidate-size! node)
  "Drop NODE's cached intrinsic size so the next view-size call
recomputes it.  Use after mutating NODE's structure (e.g. adding a
vbox body).  Static nodes also lose their cached cmds and rect."
  (cond
   ((text-node? node)    (set-text-node-cache!    node #f))
   ((fill-node? node)    (set-fill-node-cache!    node #f))
   ((spacer-node? node)  (set-spacer-node-cache!  node #f))
   ((vbox-node? node)    (set-vbox-node-cache!    node #f))
   ((hbox-node? node)    (set-hbox-node-cache!    node #f))
   ((boxed-node? node)   (set-boxed-node-cache!   node #f))
   ((pad-node? node)     (set-pad-node-cache!     node #f))
   ((margin-node? node)  (set-margin-node-cache!  node #f))
   ((align-node? node)   (set-align-node-cache!   node #f))
   ((width-node? node)   (set-width-node-cache!   node #f))
   ((height-node? node)  (set-height-node-cache!  node #f))
   ((overlay-node? node) (set-overlay-node-cache! node #f))
   ((static-node? node)
    (set-static-node-size-cache!  node #f)
    (set-static-node-cached-rect! node #f)
    (set-static-node-cached-cmds! node #f))
   ((click-node? node)   (set-click-node-cache!   node #f))
   ((link-node? node)    (set-link-node-cache!    node #f))
   ((semantic-node? node)(set-semantic-node-cache! node #f))
   ((hover-node? node)   (set-hover-node-cache!   node #f))
   ((flex-node? node)    (set-flex-node-cache!    node #f))))
