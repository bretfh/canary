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
            flex
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
  (call-with-values (lambda () (parse-style-args args))
    (lambda (children face _attrs)
      (make-vbox-node (filter (lambda (x) x) children) face))))

(define (hbox . args)
  (call-with-values (lambda () (parse-style-args args))
    (lambda (children face _attrs)
      (make-hbox-node (filter (lambda (x) x) children) face))))

(define %zero-spacer (make-spacer-node 0 0))

(define* (spacer #:optional (n #f) #:key (w 0) (h 0))
  (cond
   ((and (not n) (zero? w) (zero? h)) %zero-spacer)
   ((not n) (make-spacer-node w h))
   ((eqv? n 0) %zero-spacer)
   (else (make-spacer-node w n))))

(define (static child) (make-static-node child))

(define (join . elements)
  (apply vbox elements))

(define* (pad child #:key (top 0) (right 0) (bottom 0) (left 0) (all 0)
              (fg #f) (bg #f))
  (let ((t (if (positive? all) all top))
        (r (if (positive? all) all right))
        (b (if (positive? all) all bottom))
        (l (if (positive? all) all left))
        (f (if (or fg bg) (face #:fg fg #:bg bg #:attrs '()) #f)))
    (make-pad-node child t r b l f)))

(define* (margin child #:key (top 0) (right 0) (bottom 0) (left 0) (all 0))
  (let ((t (if (positive? all) all top))
        (r (if (positive? all) all right))
        (b (if (positive? all) all bottom))
        (l (if (positive? all) all left)))
    (make-margin-node child t r b l)))

(define* (align child mode #:key (width #f))
  (make-align-node child mode width))

(define* (width child w #:key (align 'left))
  (make-width-node child w align))

(define* (height child h #:key (valign 'top))
  (make-height-node child h valign))

(define* (fill w h #:key (fg #f) (bg #f))
  (let ((f (cond
            ((or fg bg) (face #:fg fg #:bg bg #:attrs '()))
            (else 'default))))
    (make-fill-node w h f)))

(define* (place-cursor col row #:key (style 'block))
  (make-cursor-node col row style))

(define (pin col row child)
  (make-placement col row child))

(define (overlay base . pins)
  (make-overlay-node base pins))

(define* (image src #:key (w 1) (h 1) (px 0) (py 0)
                (src-x 0) (src-y 0) (src-w 0) (src-h 0)
                (fallback #f))
  (make-image-node src w h px py src-x src-y src-w src-h
                   (or fallback (make-spacer-node w h))))

(define (on-click action child)
  "Wrap CHILD so a mouse-left press inside its rendered rect dispatches
ACTION through the app's update method. ACTION is any msg value the
app's update knows how to handle (symbol, key, list, …)."
  (make-click-node action child))

(define (on-hover child styler)
  "Wrap CHILD so the engine renders STYLER's output instead while the
mouse cursor is inside the child's rect. STYLER is a unary procedure
(lambda (child) → view-node) — return whatever view should replace the
child on hover. For a static substitute, use (lambda (_) replacement)."
  (make-hover-node child styler))

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
