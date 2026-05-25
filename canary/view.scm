(define-module (canary view)
  #:use-module (canary width)
  #:use-module (srfi srfi-9)
  #:use-module (oop goops)
  #:export (view update init
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
            vbox-node-children
            vbox-node-face

            <hbox-node>
            hbox-node?
            make-hbox-node
            hbox-node-children
            hbox-node-face

            <boxed-node>
            boxed-node?
            make-boxed-node
            boxed-node-child
            boxed-node-border
            boxed-node-face
            boxed-node-title

            <pad-node>
            pad-node?
            make-pad-node
            pad-node-child
            pad-node-top
            pad-node-right
            pad-node-bottom
            pad-node-left
            pad-node-face

            <margin-node>
            margin-node?
            make-margin-node
            margin-node-child
            margin-node-top
            margin-node-right
            margin-node-bottom
            margin-node-left

            <align-node>
            align-node?
            make-align-node
            align-node-child
            align-node-mode
            align-node-width

            <width-node>
            width-node?
            make-width-node
            width-node-child
            width-node-w
            width-node-align

            <height-node>
            height-node?
            make-height-node
            height-node-child
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
            placement-child

            <static-node>
            static-node?
            make-static-node
            static-node-child
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
            click-node-child

            <hover-node>
            hover-node?
            make-hover-node
            hover-node-child
            hover-node-styler))

(define-record-type <rect>
  (make-rect col row w h)
  rect?
  (col rect-col)
  (row rect-row)
  (w rect-w)
  (h rect-h))

(define (rect-empty? r)
  (or (<= (rect-w r) 0) (<= (rect-h r) 0)))

(define (rect=? a b)
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

(define (make-text-node str face attrs) (%text-node str face attrs #f))

(define-record-type <text-runs-node>
  (%text-runs-node runs cache) text-runs-node?
  (runs  text-runs-node-runs)
  (cache text-runs-node-cache set-text-runs-node-cache!))

(define (make-text-runs-node runs) (%text-runs-node runs #f))

(define-record-type <fill-node>
  (%fill-node w h face cache)
  fill-node?
  (w fill-node-w)
  (h fill-node-h)
  (face fill-node-face)
  (cache fill-node-cache set-fill-node-cache!))

(define (make-fill-node w h face) (%fill-node w h face #f))

(define-record-type <spacer-node>
  (%spacer-node w h cache)
  spacer-node?
  (w spacer-node-w)
  (h spacer-node-h)
  (cache spacer-node-cache set-spacer-node-cache!))

(define (make-spacer-node w h) (%spacer-node w h #f))

(define-record-type <vbox-node>
  (%vbox-node children face cache)
  vbox-node?
  (children vbox-node-children)
  (face vbox-node-face)
  (cache vbox-node-cache set-vbox-node-cache!))

(define (make-vbox-node children face) (%vbox-node children face #f))

(define-record-type <hbox-node>
  (%hbox-node children face cache)
  hbox-node?
  (children hbox-node-children)
  (face hbox-node-face)
  (cache hbox-node-cache set-hbox-node-cache!))

(define (make-hbox-node children face) (%hbox-node children face #f))

(define-record-type <boxed-node>
  (%boxed-node child border face title cache)
  boxed-node?
  (child boxed-node-child)
  (border boxed-node-border)
  (face boxed-node-face)
  (title boxed-node-title)
  (cache boxed-node-cache set-boxed-node-cache!))

(define* (make-boxed-node child border face #:optional (title #f))
  (%boxed-node child border face title #f))

(define-record-type <pad-node>
  (%pad-node child top right bottom left face cache)
  pad-node?
  (child pad-node-child)
  (top pad-node-top)
  (right pad-node-right)
  (bottom pad-node-bottom)
  (left pad-node-left)
  (face pad-node-face)
  (cache pad-node-cache set-pad-node-cache!))

(define (make-pad-node child top right bottom left face)
  (%pad-node child top right bottom left face #f))

(define-record-type <margin-node>
  (%margin-node child top right bottom left cache)
  margin-node?
  (child  margin-node-child)
  (top    margin-node-top)
  (right  margin-node-right)
  (bottom margin-node-bottom)
  (left   margin-node-left)
  (cache  margin-node-cache set-margin-node-cache!))

(define (make-margin-node child top right bottom left)
  (%margin-node child top right bottom left #f))

(define-record-type <align-node>
  (%align-node child mode width cache)
  align-node?
  (child align-node-child)
  (mode align-node-mode)
  (width align-node-width)
  (cache align-node-cache set-align-node-cache!))

(define (make-align-node child mode width) (%align-node child mode width #f))

(define-record-type <width-node>
  (%width-node child w align cache)
  width-node?
  (child width-node-child)
  (w width-node-w)
  (align width-node-align)
  (cache width-node-cache set-width-node-cache!))

(define (make-width-node child w align) (%width-node child w align #f))

(define-record-type <height-node>
  (%height-node child h valign cache)
  height-node?
  (child height-node-child)
  (h height-node-h)
  (valign height-node-valign)
  (cache height-node-cache set-height-node-cache!))

(define (make-height-node child h valign) (%height-node child h valign #f))

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

(define (make-overlay-node base overlays) (%overlay-node base overlays #f))

(define-record-type <placement>
  (make-placement col row child)
  placement?
  (col   placement-col)
  (row   placement-row)
  (child placement-child))

(define-record-type <static-node>
  (%static-node child cached-rect cached-cmds size-cache)
  static-node?
  (child static-node-child)
  (cached-rect static-node-cached-rect set-static-node-cached-rect!)
  (cached-cmds static-node-cached-cmds set-static-node-cached-cmds!)
  (size-cache static-node-size-cache set-static-node-size-cache!))

(define (make-static-node child) (%static-node child #f #f #f))

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
  (%click-node action child cache)
  click-node?
  (action click-node-action)
  (child  click-node-child)
  (cache  click-node-cache set-click-node-cache!))

(define (make-click-node action child) (%click-node action child #f))

(define-record-type <hover-node>
  (%hover-node child styler cache)
  hover-node?
  (child   hover-node-child)
  (styler  hover-node-styler)
  (cache   hover-node-cache set-hover-node-cache!))

(define (make-hover-node child styler)
  "STYLER is a unary procedure (lambda (child) → view-node) that
returns the view to render whenever the cursor is inside the node's
assigned rect. Any view transformation works — restyle the child,
swap glyphs, wrap with overlay, return a static replacement node."
  (unless (procedure? styler)
    (error "make-hover-node: STYLER must be a procedure (lambda (child) → view-node)"
           styler))
  (%hover-node child styler #f))

(define-generic view)
(define-generic update)
(define-generic init)

(define (view-node? x)
  (or (text-node? x) (text-runs-node? x)
      (fill-node? x) (spacer-node? x)
      (vbox-node? x) (hbox-node? x) (boxed-node? x)
      (pad-node? x) (margin-node? x) (align-node? x)
      (width-node? x) (height-node? x)
      (cursor-node? x) (overlay-node? x) (static-node? x)
      (image-node? x) (click-node? x) (hover-node? x)
      (is-a? x <object>)
      (string? x) (not x)))

(define (str-visible-length s) (string-display-width s))

(define-syntax-rule (memo getter setter node expr)
  (or (getter node)
      (let ((v expr)) (setter node v) v)))

(define (compute-size node)
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
          (let loop ((cs (vbox-node-children node)) (mw 0) (sh 0))
            (if (null? cs)
                (cons mw sh)
                (let ((s (view-size (car cs))))
                  (loop (cdr cs) (max mw (car s)) (+ sh (cdr s))))))))
   ((hbox-node? node)
    (memo hbox-node-cache set-hbox-node-cache! node
          (let loop ((cs (hbox-node-children node)) (sw 0) (mh 0))
            (if (null? cs)
                (cons sw mh)
                (let ((s (view-size (car cs))))
                  (loop (cdr cs) (+ sw (car s)) (max mh (cdr s))))))))
   ((boxed-node? node)
    (memo boxed-node-cache set-boxed-node-cache! node
          (let ((s (view-size (boxed-node-child node))))
            (cons (+ (car s) 2) (+ (cdr s) 2)))))
   ((pad-node? node)
    (memo pad-node-cache set-pad-node-cache! node
          (let ((s (view-size (pad-node-child node))))
            (cons (+ (car s) (pad-node-left node) (pad-node-right node))
                  (+ (cdr s) (pad-node-top node) (pad-node-bottom node))))))
   ((margin-node? node)
    (memo margin-node-cache set-margin-node-cache! node
          (let ((s (view-size (margin-node-child node))))
            (cons (+ (car s) (margin-node-left node) (margin-node-right node))
                  (+ (cdr s) (margin-node-top  node) (margin-node-bottom node))))))
   ((align-node? node)
    (memo align-node-cache set-align-node-cache! node
          (let ((s (view-size (align-node-child node))))
            (cons (or (align-node-width node) (car s)) (cdr s)))))
   ((width-node? node)
    (memo width-node-cache set-width-node-cache! node
          (let ((s (view-size (width-node-child node))))
            (cons (width-node-w node) (cdr s)))))
   ((height-node? node)
    (memo height-node-cache set-height-node-cache! node
          (let ((s (view-size (height-node-child node))))
            (cons (car s) (height-node-h node)))))
   ((overlay-node? node)
    (memo overlay-node-cache set-overlay-node-cache! node
          (view-size (overlay-node-base node))))
   ((static-node? node)
    (memo static-node-size-cache set-static-node-size-cache! node
          (view-size (static-node-child node))))
   ((image-node? node)
    (cons (image-node-w node) (image-node-h node)))
   ((click-node? node)
    (memo click-node-cache set-click-node-cache! node
          (view-size (click-node-child node))))
   ((hover-node? node)
    (memo hover-node-cache set-hover-node-cache! node
          (view-size (hover-node-child node))))
   ((is-a? node <object>)
    (cons 0 0))
   (else (cons 0 0))))

(define (view-size node) (compute-size node))

(define (invalidate-size! node)
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
   ((hover-node? node)   (set-hover-node-cache!   node #f))))
