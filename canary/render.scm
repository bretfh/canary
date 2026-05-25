(define-module (canary render)
  #:use-module (canary view)
  #:use-module (canary draw)
  #:use-module (canary borders)
  #:use-module (canary width)
  #:use-module (canary protocol)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (render
            view->cmds
            image-cmd->fallback-cmds))

(define (clamp s max-w) (string-display-clamp s max-w))

(define (rect-contains? rect x y)
  (and (<= (rect-col rect) x)
       (< x (+ (rect-col rect) (rect-w rect)))
       (<= (rect-row rect) y)
       (< y (+ (rect-row rect) (rect-h rect)))))

(define* (render node cols rows #:key (mouse-x -1) (mouse-y -1))
  (view->cmds node (make-rect 0 0 cols rows) mouse-x mouse-y))

(define (view->cmds node rect mx my)
  (cond
   ((rect-empty? rect) '())
   ((not node) '())
   ((string? node)
    (list (make-text (rect-col rect) (rect-row rect)
                     (clamp node (rect-w rect))
                     'default '())))
   ((text-node? node)
    (list (make-text (rect-col rect) (rect-row rect)
                     (clamp (text-node-str node) (rect-w rect))
                     (text-node-face node)
                     (text-node-attrs node))))
   ((text-runs-node? node)
    (render-text-runs node rect mx my))
   ((fill-node? node)
    (let* ((w (min (fill-node-w node) (rect-w rect)))
           (h (min (fill-node-h node) (rect-h rect))))
      (list (make-fill (rect-col rect) (rect-row rect) w h
                       (fill-node-face node)))))
   ((spacer-node? node) '())
   ((cursor-node? node)
    (list (make-cursor (+ (rect-col rect) (cursor-node-col node))
                       (+ (rect-row rect) (cursor-node-row node))
                       (cursor-node-style node))))
   ((vbox-node? node)    (render-vbox    node rect mx my))
   ((hbox-node? node)    (render-hbox    node rect mx my))
   ((boxed-node? node)   (render-boxed   node rect mx my))
   ((pad-node? node)     (render-pad     node rect mx my))
   ((margin-node? node)  (render-margin  node rect mx my))
   ((align-node? node)   (render-align   node rect mx my))
   ((width-node? node)   (render-width   node rect mx my))
   ((height-node? node)  (render-height  node rect mx my))
   ((overlay-node? node)
    (append (view->cmds (overlay-node-base node) rect mx my)
            (append-map
             (lambda (p)
               (let* ((col   (placement-col p))
                      (row   (placement-row p))
                      (child (placement-child p))
                      (s (view-size child))
                      (cw (min (car s) (- (rect-w rect)
                                          (- col (rect-col rect)))))
                      (ch (min (cdr s) (- (rect-h rect)
                                          (- row (rect-row rect))))))
                 (view->cmds child (make-rect col row cw ch) mx my)))
             (overlay-node-overlays node))))
   ((static-node? node)
    (let ((cached (static-node-cached-rect node)))
      (if (and cached (rect=? cached rect))
          (static-node-cached-cmds node)
          (let ((cmds (view->cmds (static-node-child node) rect mx my)))
            (set-static-node-cached-rect! node rect)
            (set-static-node-cached-cmds! node cmds)
            cmds))))
   ((image-node? node)
    (let* ((w (min (image-node-w node) (rect-w rect)))
           (h (min (image-node-h node) (rect-h rect))))
      (list (make-image (rect-col rect) (rect-row rect) w h
                        (image-node-px node) (image-node-py node)
                        (image-node-src-x node) (image-node-src-y node)
                        (image-node-src-w node) (image-node-src-h node)
                        (image-node-src node)
                        (image-node-fallback node)))))
   ((click-node? node)
    (let ((child-cmds (view->cmds (click-node-child node) rect mx my)))
      (append child-cmds
              (list (make-clickable (rect-col rect) (rect-row rect)
                                    (rect-w rect) (rect-h rect)
                                    (click-node-action node))))))
   ((hover-node? node)
    (let* ((child     (hover-node-child node))
           (hot?      (rect-contains? rect mx my))
           (effective (if hot? ((hover-node-styler node) child) child)))
      (view->cmds effective rect mx my)))
   ((flex-node? node)
    (view->cmds (flex-node-body node) rect mx my))
   ((is-a? node <object>)
    (view->cmds (memoized-view node (size (rect-w rect) (rect-h rect)))
                rect mx my))
   (else '())))

(define (image-cmd->fallback-cmds cmd)
  (view->cmds (image-fallback cmd)
              (make-rect (image-col cmd) (image-row cmd)
                         (image-w cmd) (image-h cmd))
              -1 -1))

(define (bg-fill-cmds face rect)
  (if face
      (list (make-fill (rect-col rect) (rect-row rect)
                       (rect-w rect) (rect-h rect)
                       face))
      '()))

;; Major-axis size of one box item before flex distribution. GOOPS
;; items materialize via memoized-view at a probe size; layout items
;; report their intrinsic size directly.
(define (probe-major item probe-w probe-h axis)
  ;; axis 'v → return height; 'h → return width
  (cond
   ((flex-node? item)
    (probe-major (flex-node-body item) probe-w probe-h axis))
   (else
    (let ((s (cond
              ((is-a? item <object>)
               (view-size (memoized-view item (size probe-w probe-h))))
              (else (view-size item)))))
      (if (eq? axis 'v) (cdr s) (car s))))))

(define (flex-info item)
  (cond
   ((flex-node? item) (cons (flex-node-grow item) (flex-node-shrink item)))
   (else (cons 0 0))))

;; Walk the items list once. Return three parallel lists:
;;  - intrinsic majors (cells)
;;  - grow shares
;;  - shrink shares
;; Plus totals.
(define (measure-box items rect axis)
  (let lp ((cs items) (majors '()) (grows '()) (shrinks '())
           (sum-major 0) (sum-grow 0) (sum-shrink 0))
    (cond
     ((null? cs)
      (values (reverse majors) (reverse grows) (reverse shrinks)
              sum-major sum-grow sum-shrink))
     (else
      (let* ((it (car cs))
             (m  (if (eq? axis 'v)
                     (probe-major it (rect-w rect) (rect-h rect) 'v)
                     (probe-major it (rect-w rect) (rect-h rect) 'h)))
             (fi (flex-info it))
             (g  (car fi))
             (s  (cdr fi)))
        (lp (cdr cs) (cons m majors) (cons g grows) (cons s shrinks)
            (+ sum-major m) (+ sum-grow g) (+ sum-shrink s)))))))

;; Distribute SURPLUS (≥0) across the items by their grow shares.
;; Remainder cells from integer rounding go to the last flex item so
;; the box exactly fills. Returns a list of bonuses parallel to GROWS.
(define (distribute-bonuses majors grows surplus sum-grow)
  (cond
   ((or (zero? surplus) (zero? sum-grow))
    (map (lambda (_) 0) grows))
   (else
    (let* ((bonuses
            (map (lambda (g)
                   (if (zero? g) 0
                       (inexact->exact (floor (* surplus (/ g sum-grow))))))
                 grows))
           (used  (apply + bonuses))
           (left  (- surplus used))
           ;; tack the rounding remainder onto the last flex item
           (reversed
            (let loop ((bs (reverse bonuses)) (gs (reverse grows))
                       (remaining left) (acc '()))
              (cond
               ((null? bs) acc)
               ((and (positive? remaining) (positive? (car gs)))
                (append (reverse (cdr bs))
                        (cons (+ (car bs) remaining) acc)))
               (else (loop (cdr bs) (cdr gs) remaining (cons (car bs) acc)))))))
      reversed))))

;; Distribute DEFICIT (≥0) across the items by their shrink shares.
;; Items can't shrink below 0. Same rounding strategy as bonuses.
(define (distribute-cuts majors shrinks deficit sum-shrink)
  (cond
   ((or (zero? deficit) (zero? sum-shrink))
    (map (lambda (_) 0) shrinks))
   (else
    (let loop ((ms majors) (ss shrinks) (acc '()) (sum sum-shrink) (left deficit))
      (cond
       ((null? ms) (reverse acc))
       (else
        (let* ((m (car ms)) (s (car ss))
               (raw (if (zero? sum) 0
                        (inexact->exact (floor (* left (/ s sum))))))
               (cut (min m raw)))
           (loop (cdr ms) (cdr ss) (cons cut acc)
                 (- sum s) (- left cut)))))))))

(define (assigned-majors majors grows shrinks total-major available sum-grow sum-shrink)
  (cond
   ((< total-major available)
    (let ((bonuses (distribute-bonuses majors grows
                                       (- available total-major) sum-grow)))
      (map + majors bonuses)))
   ((> total-major available)
    (let ((cuts (distribute-cuts majors shrinks
                                 (- total-major available) sum-shrink)))
      (map - majors cuts)))
   (else majors)))

;; Minor-axis size of one item. Mirrors probe-major's GOOPS handling
;; so a tall GOOPS item in an hbox reports its natural width.
(define (probe-minor item probe-w probe-h axis)
  (cond
   ((flex-node? item)
    (probe-minor (flex-node-body item) probe-w probe-h axis))
   (else
    (let ((s (cond
              ((is-a? item <object>)
               (view-size (memoized-view item (size probe-w probe-h))))
              (else (view-size item)))))
      (if (eq? axis 'v) (car s) (cdr s))))))

(define (render-vbox node rect mx my)
  (let ((face (vbox-node-face node))
        (items (vbox-node-children node)))
    (call-with-values (lambda () (measure-box items rect 'v))
      (lambda (majors grows shrinks total-h sum-grow sum-shrink)
        (let ((assigned (assigned-majors majors grows shrinks total-h
                                         (rect-h rect) sum-grow sum-shrink)))
          (append
           (bg-fill-cmds face rect)
           (let loop ((cs items) (hs assigned)
                      (row (rect-row rect)) (remaining (rect-h rect))
                      (acc '()))
             (cond
              ((or (null? cs) (<= remaining 0)) (reverse acc))
              (else
               (let* ((it (car cs))
                      (ch (max 0 (min (car hs) remaining)))
                      (cw (min (probe-minor it (rect-w rect) ch 'v)
                               (rect-w rect)))
                      (sub (make-rect (rect-col rect) row cw ch))
                      (cmds (view->cmds it sub mx my)))
                 (loop (cdr cs) (cdr hs) (+ row ch) (- remaining ch)
                       (append (reverse cmds) acc))))))))))))

(define (render-hbox node rect mx my)
  (let ((face (hbox-node-face node))
        (items (hbox-node-children node)))
    (call-with-values (lambda () (measure-box items rect 'h))
      (lambda (majors grows shrinks total-w sum-grow sum-shrink)
        (let ((assigned (assigned-majors majors grows shrinks total-w
                                         (rect-w rect) sum-grow sum-shrink)))
          (append
           (bg-fill-cmds face rect)
           (let loop ((cs items) (ws assigned)
                      (col (rect-col rect)) (remaining (rect-w rect))
                      (acc '()))
             (cond
              ((or (null? cs) (<= remaining 0)) (reverse acc))
              (else
               (let* ((it (car cs))
                      (cw (max 0 (min (car ws) remaining)))
                      (ch (min (probe-minor it cw (rect-h rect) 'h)
                               (rect-h rect)))
                      (sub (make-rect col (rect-row rect) cw ch))
                      (cmds (view->cmds it sub mx my)))
                 (loop (cdr cs) (cdr ws) (+ col cw) (- remaining cw)
                       (append (reverse cmds) acc))))))))))))

(define (splice-title top-mid title)
  (cond
   ((not title) top-mid)
   ((not (string? title)) top-mid)
   (else
    (let* ((tag    (string-append " " title " "))
           (tag-w  (string-length tag))
           (mid-w  (string-length top-mid))
           (offset 2))
      (cond
       ((> (+ offset tag-w) mid-w) top-mid)
       (else
        (string-append (substring top-mid 0 offset)
                       tag
                       (substring top-mid (+ offset tag-w) mid-w))))))))

(define (render-boxed node rect mx my)
  (cond
   ((or (< (rect-w rect) 2) (< (rect-h rect) 2)) '())
   (else
    (let* ((border (boxed-node-border node))
           (face (boxed-node-face node))
           (title (boxed-node-title node))
           (col (rect-col rect))
           (row (rect-row rect))
           (w (rect-w rect))
           (h (rect-h rect))
           (inner-w (- w 2))
           (inner-h (- h 2))
           (inner-rect (make-rect (+ col 1) (+ row 1) inner-w inner-h))
           (top-mid (splice-title
                     (make-string inner-w (string-ref (border-top border) 0))
                     title))
           (bot-mid (make-string inner-w (string-ref (border-bottom border) 0))))
      (append
       (bg-fill-cmds face rect)
       (list (make-text col row
                        (string-append (border-tl border) top-mid (border-tr border))
                        face '()))
       (let loop ((r (+ row 1)) (end (+ row h -1)) (acc '()))
         (cond
          ((>= r end) (reverse acc))
          (else
           (loop (+ r 1) end
                 (cons (make-text col r (border-left border) face '())
                       (cons (make-text (+ col w -1) r (border-right border) face '())
                             acc))))))
       (list (make-text col (+ row h -1)
                        (string-append (border-bl border) bot-mid (border-br border))
                        face '()))
       (view->cmds (boxed-node-child node) inner-rect mx my))))))

(define (render-pad node rect mx my)
  (let* ((t (pad-node-top node))
         (r (pad-node-right node))
         (b (pad-node-bottom node))
         (l (pad-node-left node))
         (inner (make-rect (+ (rect-col rect) l)
                           (+ (rect-row rect) t)
                           (max 0 (- (rect-w rect) l r))
                           (max 0 (- (rect-h rect) t b)))))
    (append (bg-fill-cmds (pad-node-face node) rect)
            (view->cmds (pad-node-child node) inner mx my))))

(define (render-margin node rect mx my)
  (let* ((t (margin-node-top    node))
         (r (margin-node-right  node))
         (b (margin-node-bottom node))
         (l (margin-node-left   node))
         (inner (make-rect (+ (rect-col rect) l)
                           (+ (rect-row rect) t)
                           (max 0 (- (rect-w rect) l r))
                           (max 0 (- (rect-h rect) t b)))))
    (view->cmds (margin-node-child node) inner mx my)))

(define (render-text-runs node rect mx my)
  (let loop ((runs (text-runs-node-runs node))
             (col  (rect-col rect))
             (acc  '())
             (rem  (rect-w rect)))
    (cond
     ((or (null? runs) (<= rem 0)) (reverse acc))
     (else
      (let* ((run (car runs))
             (s   (view-size run))
             (w   (min (car s) rem))
             (sub (make-rect col (rect-row rect) w 1))
             (cmds (view->cmds run sub mx my)))
        (loop (cdr runs) (+ col w) (append (reverse cmds) acc) (- rem w)))))))

(define (render-align node rect mx my)
  (let* ((child (align-node-child node))
         (mode (align-node-mode node))
         (target-w (or (align-node-width node) (rect-w rect)))
         (s (view-size child))
         (cw (min (car s) target-w))
         (slack (max 0 (- target-w cw)))
         (offset (case mode
                   ((center) (quotient slack 2))
                   ((right) slack)
                   (else 0)))
         (sub (make-rect (+ (rect-col rect) offset)
                         (rect-row rect)
                         cw
                         (rect-h rect))))
    (view->cmds child sub mx my)))

(define (render-width node rect mx my)
  (let* ((target-w (min (width-node-w node) (rect-w rect)))
         (child (width-node-child node))
         (align (width-node-align node))
         (s (view-size child))
         (cw (min (car s) target-w))
         (slack (max 0 (- target-w cw)))
         (offset (case align
                   ((center) (quotient slack 2))
                   ((right) slack)
                   (else 0)))
         (sub (make-rect (+ (rect-col rect) offset)
                         (rect-row rect)
                         cw
                         (rect-h rect))))
    (view->cmds child sub mx my)))

(define (render-height node rect mx my)
  (let* ((target-h (min (height-node-h node) (rect-h rect)))
         (child (height-node-child node))
         (valign (height-node-valign node))
         (s (view-size child))
         (ch (min (cdr s) target-h))
         (slack (max 0 (- target-h ch)))
         (offset (case valign
                   ((center) (quotient slack 2))
                   ((bottom) slack)
                   (else 0)))
         (sub (make-rect (rect-col rect)
                         (+ (rect-row rect) offset)
                         (rect-w rect)
                         ch)))
    (view->cmds child sub mx my)))
