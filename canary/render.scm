(define-module (canary render)
  #:use-module (canary view)
  #:use-module (canary draw)
  #:use-module (canary faces)
  #:use-module (canary borders)
  #:use-module (canary width)
  #:use-module (canary protocol)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (render
            view->cmds
            image-cmd->fallback-cmds))

(define (clamp s max-w)
  "Truncate string S to at most MAX-W display columns (wide chars
counted correctly)."
  (string-display-clamp s max-w))

(define (wrap-paragraph str width)
  "Greedy word-wrap STR to WIDTH columns.  Words separated by spaces;
words longer than WIDTH are hard-broken into width-sized chunks."
  (cond
   ((or (<= width 0) (string-null? str)) (list str))
   (else
    (let lp ((words (string-split str #\space))
             (lines '())
             (cur ""))
      (cond
       ((null? words)
        (reverse (if (string-null? cur) lines (cons cur lines))))
       (else
        (let* ((w (car words))
               (joined (cond ((string-null? cur) w)
                             (else (string-append cur " " w)))))
          (cond
           ((<= (string-display-width joined) width)
            (lp (cdr words) lines joined))
           ((not (string-null? cur))
            (lp words (cons cur lines) ""))
           (else
            (let break ((rem w) (lines lines))
              (cond
               ((<= (string-display-width rem) width)
                (lp (cdr words) lines rem))
               (else
                (let* ((head     (string-display-clamp rem width))
                       (head-len (max 1 (string-length head)))
                       (rest     (substring rem head-len)))
                  (break rest (cons head lines)))))))))))))))

(define (wrap-text str width)
  "Split STR on newlines, word-wrap each paragraph to WIDTH. Returns a
flat list of line strings."
  (apply append
         (map (lambda (p) (wrap-paragraph p width))
              (string-split str #\newline))))

(define (render-wrap node rect)
  "Word-wrap a <wrap-node> NODE into RECT.  Wraps the node's string
to RECT's width, clips vertically to RECT's height, and emits one
text cmd per visible line."
  (let* ((w (rect-w rect))
         (h (rect-h rect))
         (face (wrap-node-face node))
         (attrs (wrap-node-attrs node))
         (lines (wrap-text (wrap-node-str node) w))
         (visible (let lp ((rem lines) (acc '()) (k 0))
                    (cond
                     ((or (null? rem) (>= k h)) (reverse acc))
                     (else (lp (cdr rem) (cons (car rem) acc) (+ k 1)))))))
    (let lp ((ls visible) (row (rect-row rect)) (acc '()))
      (cond
       ((null? ls) (reverse acc))
       (else
        (lp (cdr ls) (+ row 1)
            (cons (make-text (rect-col rect) row (car ls) face attrs) acc)))))))

(define (rect-contains? rect x y)
  "Return #t if cell (X, Y) lies inside RECT (half-open on the
right and bottom edges)."
  (and (<= (rect-col rect) x)
       (< x (+ (rect-col rect) (rect-w rect)))
       (<= (rect-row rect) y)
       (< y (+ (rect-row rect) (rect-h rect)))))

(define* (render node cols rows #:key (mouse-x -1) (mouse-y -1))
  "Render NODE at the full COLS×ROWS screen and return a flat draw
cmd list.  MOUSE-X / MOUSE-Y position the mouse for hit-testing
hover and click nodes; pass -1 for no pointer."
  (view->cmds node (make-rect 0 0 cols rows) mouse-x mouse-y))

(define (view->cmds node rect mx my)
  "Render NODE into RECT, with mouse position (MX, MY) used for
hover/click hit-testing.  Returns a flat list of draw cmds.  The
main recursion: dispatches on node kind, slices RECT for items,
and threads MX/MY through.

A `cursor-node` is allowed through an empty RECT — its intrinsic
size is (0 . 0) so overlay placement clipping always produces a
(col, row, 0, 0) sub-rect, and bailing on rect-empty? here would
silently drop the cursor placement.  Cursor cmds don't read
RECT-W/H; they only need RECT-COL/ROW to position the caret."
  (cond
   ((and (rect-empty? rect) (not (cursor-node? node))) '())
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
   ((cells-node? node)
    ;; Pre-rendered block.  Hand the chars/faces buffers straight to
    ;; the backend via one cells-cmd — no per-cell text-cmd allocation.
    ;; Pass cells-node-w as src-w so the backend reads each row at the
    ;; node's native stride even when the destination rect is narrower
    ;; (PTY widget whose term-width briefly exceeds the resized grid).
    (list (make-cells (rect-col rect) (rect-row rect)
                      (min (cells-node-w node) (rect-w rect))
                      (min (cells-node-h node) (rect-h rect))
                      (cells-node-chars node)
                      (cells-node-faces node)
                      (cells-node-w node))))
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
                      (body (placement-body p))
                      (s (view-size body))
                      (cw (min (car s) (- (rect-w rect)
                                          (- col (rect-col rect)))))
                      (ch (min (cdr s) (- (rect-h rect)
                                          (- row (rect-row rect))))))
                 (view->cmds body (make-rect col row cw ch) mx my)))
             (overlay-node-overlays node))))
   ((static-node? node)
    (let ((cached (static-node-cached-rect node)))
      (if (and cached (rect=? cached rect))
          (static-node-cached-cmds node)
          (let ((cmds (view->cmds (static-node-body node) rect mx my)))
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
    (let ((body-cmds (view->cmds (click-node-body node) rect mx my)))
      (append body-cmds
              (list (make-clickable (rect-col rect) (rect-row rect)
                                    (rect-w rect) (rect-h rect)
                                    (click-node-action node)
                                    (click-node-right-action node))))))
   ((link-node? node)
    (let ((uri (link-node-uri node)))
      (map (lambda (cmd)
             (cond
              ((text-cmd? cmd)
               (make-text (text-col cmd) (text-row cmd) (text-str cmd)
                          (with-hyperlink (text-face cmd) uri)
                          (text-attrs cmd)))
              (else cmd)))
           (view->cmds (link-node-body node) rect mx my))))
   ((semantic-node? node)
    (let ((kind (semantic-node-kind node)))
      (map (lambda (cmd)
             (cond
              ((text-cmd? cmd)
               (make-text (text-col cmd) (text-row cmd) (text-str cmd)
                          (with-semantic (text-face cmd) kind)
                          (text-attrs cmd)))
              (else cmd)))
           (view->cmds (semantic-node-body node) rect mx my))))
   ((hover-node? node)
    (let* ((body     (hover-node-body node))
           (hot?      (rect-contains? rect mx my))
           (effective (if hot? ((hover-node-styler node) body) body)))
      (view->cmds effective rect mx my)))
   ((flex-node? node)
    (view->cmds (flex-node-body node) rect mx my))
   ((keymap-node? node)
    (view->cmds (keymap-node-body node) rect mx my))
   ((wrap-node? node)
    (render-wrap node rect))
   ((is-a? node <object>)
    (view->cmds (memoized-view node) rect mx my))
   (else '())))

(define (image-cmd->fallback-cmds cmd)
  "Render the fallback view of image CMD as draw cmds at CMD's
rect.  Used by backends without graphics support."
  (view->cmds (image-fallback cmd)
              (make-rect (image-col cmd) (image-row cmd)
                         (image-w cmd) (image-h cmd))
              -1 -1))

(define (bg-fill-cmds face rect)
  "Return a one-element list with a fill cmd painting RECT in FACE,
or empty if FACE is #f.  Used to apply container background colours."
  (if face
      (list (make-fill (rect-col rect) (rect-row rect)
                       (rect-w rect) (rect-h rect)
                       face))
      '()))

(define (probe-major item probe-w probe-h axis)
  "Return the major-axis size (in cells) of one box ITEM before
flex distribution.  AXIS is 'v (return height) or 'h (return width).
Descends through wrapper nodes (flex, boxed, pad, margin, width,
height, align, static, click, hover) so the widget buried
inside is materialised at the right probe size and measured
properly.  Without this, view-size on (boxed widget) would see the
widget's (0,0) intrinsic and report just the border overhead."
  (let ((major (lambda (s) (if (eq? axis 'v) (cdr s) (car s)))))
    (cond
     ((flex-node? item)
      (probe-major (flex-node-body item) probe-w probe-h axis))
     ((boxed-node? item)
      (+ 2 (probe-major (boxed-node-body item)
                        (max 0 (- probe-w 2)) (max 0 (- probe-h 2)) axis)))
     ((pad-node? item)
      (let* ((om (if (eq? axis 'v)
                     (+ (pad-node-top item) (pad-node-bottom item))
                     (+ (pad-node-left item) (pad-node-right item))))
             (on (if (eq? axis 'v)
                     (+ (pad-node-left item) (pad-node-right item))
                     (+ (pad-node-top item) (pad-node-bottom item)))))
        (+ om (probe-major (pad-node-body item)
                           (max 0 (- probe-w (if (eq? axis 'v) on om)))
                           (max 0 (- probe-h (if (eq? axis 'v) om on)))
                           axis))))
     ((margin-node? item)
      (let* ((om (if (eq? axis 'v)
                     (+ (margin-node-top item) (margin-node-bottom item))
                     (+ (margin-node-left item) (margin-node-right item))))
             (on (if (eq? axis 'v)
                     (+ (margin-node-left item) (margin-node-right item))
                     (+ (margin-node-top item) (margin-node-bottom item)))))
        (+ om (probe-major (margin-node-body item)
                           (max 0 (- probe-w (if (eq? axis 'v) on om)))
                           (max 0 (- probe-h (if (eq? axis 'v) om on)))
                           axis))))
     ((width-node? item)
      (if (eq? axis 'h)
          (width-node-w item)
          (probe-major (width-node-body item)
                       (min probe-w (width-node-w item)) probe-h axis)))
     ((height-node? item)
      (if (eq? axis 'v)
          (height-node-h item)
          (probe-major (height-node-body item)
                       probe-w (min probe-h (height-node-h item)) axis)))
     ((align-node? item)
      (probe-major (align-node-body item) probe-w probe-h axis))
     ((static-node? item)
      (probe-major (static-node-body item) probe-w probe-h axis))
     ((click-node? item)
      (probe-major (click-node-body item) probe-w probe-h axis))
     ((hover-node? item)
      (probe-major (hover-node-body item) probe-w probe-h axis))
     ((keymap-node? item)
      (probe-major (keymap-node-body item) probe-w probe-h axis))
     ((is-a? item <object>)
      ;; Probe at minimum size on the measured axis (1). Do NOT memoize:
      ;; the probe-size tree must not leak into the render cache, or the
      ;; subsequent real render call (at the actual rect size) hits the
      ;; cached probe tree and renders at probe size instead.
      (major (view-size (view item))))
     (else (major (view-size item))))))

(define (flex-info item)
  "Return (GROW . SHRINK) for ITEM, treating non-flex items as
0/0."
  (cond
   ((flex-node? item) (cons (flex-node-grow item) (flex-node-shrink item)))
   (else (cons 0 0))))

(define (measure-box items rect axis)
  "Walk ITEMS once measuring along AXIS.  Return six values: a list
of intrinsic major sizes, a list of grow shares, a list of shrink
shares, and the totals (sum-major, sum-grow, sum-shrink)."
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

(define (distribute-bonuses majors grows surplus sum-grow)
  "Distribute SURPLUS (≥0) cells across the items by their GROWS
shares.  Remainder cells from integer rounding go to the last flex
item so the box exactly fills.  Returns a list of bonus cell counts
parallel to GROWS."
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

(define (distribute-cuts majors shrinks deficit sum-shrink)
  "Distribute DEFICIT (≥0) cells across the items by their SHRINKS
shares.  Items can't shrink below 0; same rounding strategy as
`distribute-bonuses`.  Returns a list of cut cell counts parallel
to SHRINKS."
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
  "Combine intrinsic MAJORS with flex GROWS / SHRINKS so the sum
matches AVAILABLE cells.  Grows distribute surplus; shrinks
distribute deficit; equal-size case is identity."
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

(define (probe-minor item probe-w probe-h axis)
  "Return the minor-axis size (in cells) of one box ITEM.  AXIS is
'v (vbox; minor is width) or 'h (hbox; minor is height).  Mirrors
probe-major's widget handling so a tall widget in an hbox
reports its natural width."
  (cond
   ((flex-node? item)
    (probe-minor (flex-node-body item) probe-w probe-h axis))
   (else
    (let ((s (cond
              ((is-a? item <object>) (view-size (view item)))
              (else (view-size item)))))
      (if (eq? axis 'v) (car s) (cdr s))))))

(define (fills-cross-axis? item)
  "Return #t if ITEM should fill the box's cross axis.  Only `flex`
wrappers do; everything else (including bare widgets and
layout containers like `boxed`) sizes to content.  To make a box
span the full cross axis, wrap it: `(flex (boxed widget))`."
  (flex-node? item))

(define (cross-size-for item pw ph full-cross axis)
  "Return the cross-axis cell count to grant ITEM in a box.  ITEMs
that fill the cross axis get FULL-CROSS; others get min of their
intrinsic minor size (probed with PW/PH along AXIS) and FULL-CROSS."
  (cond
   ((fills-cross-axis? item) full-cross)
   (else (min (probe-minor item pw ph axis) full-cross))))

(define (render-vbox node rect mx my)
  "Render a <vbox-node> into RECT: probe each body's intrinsic
height, distribute surplus/deficit through flex grow/shrink, then
render each body into its row slice with width per cross-axis
policy."
  (let ((face (vbox-node-face node))
        (items (vbox-node-items node)))
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
                      (cw (cross-size-for it (rect-w rect) ch
                                          (rect-w rect) 'v))
                      (sub (make-rect (rect-col rect) row cw ch))
                      (cmds (view->cmds it sub mx my)))
                 (loop (cdr cs) (cdr hs) (+ row ch) (- remaining ch)
                       (append (reverse cmds) acc))))))))))))

(define (render-hbox node rect mx my)
  "Render an <hbox-node> into RECT: probe each body's intrinsic
width, distribute surplus/deficit through flex grow/shrink, then
render each body into its column slice with height per cross-axis
policy."
  (let ((face (hbox-node-face node))
        (items (hbox-node-items node)))
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
                      (ch (cross-size-for it cw (rect-h rect)
                                          (rect-h rect) 'h))
                      (sub (make-rect col (rect-row rect) cw ch))
                      (cmds (view->cmds it sub mx my)))
                 (loop (cdr cs) (cdr ws) (+ col cw) (- remaining cw)
                       (append (reverse cmds) acc))))))))))))

(define (splice-title top-mid title)
  "Overlay a TITLE string into TOP-MID (the run of top-border
characters of a boxed node), padded with surrounding spaces.
Returns TOP-MID unchanged when TITLE is #f, not a string, or
doesn't fit."
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
  "Render a <boxed-node>: emit the four border glyphs, the top run
with optional title spliced in, the side runs, the bottom run, and
recurse into the body within the inner rect.  Returns the empty
list if RECT is too small for the border (less than 2×2)."
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
       (view->cmds (boxed-node-body node) inner-rect mx my))))))

(define (render-pad node rect mx my)
  "Render a <pad-node>: paint the optional background face across
RECT, then render the body into the shrunken inner rect derived
from the pad amounts."
  (let* ((t (pad-node-top node))
         (r (pad-node-right node))
         (b (pad-node-bottom node))
         (l (pad-node-left node))
         (inner (make-rect (+ (rect-col rect) l)
                           (+ (rect-row rect) t)
                           (max 0 (- (rect-w rect) l r))
                           (max 0 (- (rect-h rect) t b)))))
    (append (bg-fill-cmds (pad-node-face node) rect)
            (view->cmds (pad-node-body node) inner mx my))))

(define (render-margin node rect mx my)
  "Render a <margin-node>: render the body into the shrunken
inner rect derived from the margin amounts.  Unlike pad, no
background fill — margin cells are transparent."
  (let* ((t (margin-node-top    node))
         (r (margin-node-right  node))
         (b (margin-node-bottom node))
         (l (margin-node-left   node))
         (inner (make-rect (+ (rect-col rect) l)
                           (+ (rect-row rect) t)
                           (max 0 (- (rect-w rect) l r))
                           (max 0 (- (rect-h rect) t b)))))
    (view->cmds (margin-node-body node) inner mx my)))

(define (render-text-runs node rect mx my)
  "Render a <text-runs-node>: lay the runs left to right on RECT's
top row, advancing the column by each run's intrinsic width and
stopping when RECT's width is exhausted."
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

(define (clip-cmds cmds rect)
  (let ((rl (rect-col rect))
        (rt (rect-row rect))
        (rr (+ (rect-col rect) (rect-w rect)))
        (rb (+ (rect-row rect) (rect-h rect))))
    (filter-map
     (lambda (c)
       (cond
        ((text-cmd? c)
         (cond
          ((or (< (text-row c) rt) (>= (text-row c) rb)) #f)
          (else
           (let* ((col   (text-col c))
                  (str   (text-str c))
                  (w     (string-display-width str))
                  (end   (+ col w)))
             (cond
              ((or (>= col rr) (<= end rl)) #f)
              ((and (>= col rl) (<= end rr)) c)
              (else
               (let* ((left-skip  (max 0 (- rl col)))
                      (visible-w  (max 0 (min (- rr (max col rl))
                                              (- w left-skip))))
                      (clipped    (string-display-clamp
                                   (if (zero? left-skip) str
                                       (substring str
                                                  (min left-skip (string-length str))))
                                   visible-w)))
                 (make-text (max col rl) (text-row c) clipped
                            (text-face c) (text-attrs c)))))))))
        ((fill-cmd? c)
         (let* ((fl (fill-col c))
                (ft (fill-row c))
                (fr (+ fl (fill-w c)))
                (fb (+ ft (fill-h c)))
                (il (max fl rl)) (it (max ft rt))
                (ir (min fr rr)) (ib (min fb rb)))
           (cond
            ((or (<= ir il) (<= ib it)) #f)
            (else (make-fill il it (- ir il) (- ib it) (fill-face c))))))
        ((cursor-cmd? c)
         (cond
          ((or (< (cursor-row c) rt) (>= (cursor-row c) rb)
               (< (cursor-col c) rl) (>= (cursor-col c) rr))
           #f)
          (else c)))
        (else c)))
     cmds)))

(define (render-align node rect mx my)
  "Render an <align-node>: position the body within an alignment
slot of the rect, on both axes.  When the body overflows on an
axis, the anchored edge ('right or 'bottom or the centered halves)
stays inside the slot and the opposite edge clips off-rect — useful
for chat-style tail anchoring and right-aligned status info."
  (let* ((body  (align-node-body node))
         (h-mode (align-node-h node))
         (v-mode (align-node-v node))
         (target-w (or (align-node-width  node) (rect-w rect)))
         (target-h (or (align-node-height node) (rect-h rect)))
         (s (if (is-a? body <object>)
                (view-size (view body))
                (view-size body)))
         (cw (car s))
         (ch (cdr s))
         (slack-w (- target-w cw))    ; can be negative on overflow
         (slack-h (- target-h ch))
         (offset-x (case h-mode
                     ((center) (quotient slack-w 2))
                     ((right)  slack-w)
                     (else     0)))
         (offset-y (case v-mode
                     ((middle) (quotient slack-h 2))
                     ((bottom) slack-h)
                     (else     0)))
         (sub (make-rect (+ (rect-col rect) offset-x)
                         (+ (rect-row rect) offset-y)
                         cw
                         ch)))
    (clip-cmds (view->cmds body sub mx my) rect)))

(define (render-width node rect mx my)
  "Render a <width-node>: render the body into a target-width
slot (clamped to RECT's width) using the node's align mode for
placement when the body is narrower."
  (let* ((target-w (min (width-node-w node) (rect-w rect)))
         (body (width-node-body node))
         (align (width-node-align node))
         (s (view-size body))
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
    (view->cmds body sub mx my)))

(define (render-height node rect mx my)
  "Render a <height-node>: render the body into a target-height
slot (clamped to RECT's height) using the node's valign mode for
placement when the body is shorter."
  (let* ((target-h (min (height-node-h node) (rect-h rect)))
         (body (height-node-body node))
         (valign (height-node-valign node))
         (s (view-size body))
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
    (view->cmds body sub mx my)))
