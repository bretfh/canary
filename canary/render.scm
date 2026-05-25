(define-module (canary render)
  #:use-module (canary view)
  #:use-module (canary draw)
  #:use-module (canary borders)
  #:use-module (canary width)
  #:use-module (canary protocol)
  #:use-module (srfi srfi-1)
  #:export (render
            view->cmds
            image-cmd->fallback-cmds
            *mouse-x*
            *mouse-y*
            *frame-size*))

(define (clamp s max-w) (string-display-clamp s max-w))

;; Cursor position threaded into render. -1 means "no cursor seen yet";
;; hover-nodes won't trigger styling. Engine rebinds per-frame.
(define *mouse-x* (make-parameter -1))
(define *mouse-y* (make-parameter -1))

;; Current frame size — a <size> (or #f if unavailable). View-procs in
;; <stateful> nodes can read this to layout against the terminal. The
;; engine binds this in render-frame.
(define *frame-size* (make-parameter #f))

(define (rect-contains? rect x y)
  (and (<= (rect-col rect) x)
       (< x (+ (rect-col rect) (rect-w rect)))
       (<= (rect-row rect) y)
       (< y (+ (rect-row rect) (rect-h rect)))))

(define* (render node cols rows #:key (mouse-x #f) (mouse-y #f) (frame-size #f))
  (parameterize ((*mouse-x* (or mouse-x (*mouse-x*)))
                 (*mouse-y* (or mouse-y (*mouse-y*)))
                 (*frame-size* (or frame-size (size cols rows))))
    (view->cmds node (make-rect 0 0 cols rows))))

(define (view->cmds node rect)
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
    (render-text-runs node rect))
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
   ((vbox-node? node)
    (render-vbox node rect))
   ((hbox-node? node)
    (render-hbox node rect))
   ((boxed-node? node)
    (render-boxed node rect))
   ((pad-node? node)
    (render-pad node rect))
   ((margin-node? node)
    (render-margin node rect))
   ((align-node? node)
    (render-align node rect))
   ((width-node? node)
    (render-width node rect))
   ((height-node? node)
    (render-height node rect))
   ((overlay-node? node)
    (append (view->cmds (overlay-node-base node) rect)
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
                 (view->cmds child (make-rect col row cw ch))))
             (overlay-node-overlays node))))
   ((static-node? node)
    (let ((cached (static-node-cached-rect node)))
      (if (and cached (rect=? cached rect))
          (static-node-cached-cmds node)
          (let ((cmds (view->cmds (static-node-child node) rect)))
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
    (let ((child-cmds (view->cmds (click-node-child node) rect)))
      (append child-cmds
              (list (make-clickable (rect-col rect) (rect-row rect)
                                    (rect-w rect) (rect-h rect)
                                    (click-node-action node))))))
   ((hover-node? node)
    (let* ((child  (hover-node-child node))
           (hot?   (rect-contains? rect (*mouse-x*) (*mouse-y*)))
           (effective (if hot? ((hover-node-styler node) child) child)))
      (view->cmds effective rect)))
   ;; Stateful nodes expand into their view-proc's tree. The renderer
   ;; doesn't inspect state — it just walks through. State lifecycle
   ;; (init, react, invalidate) is the engine's job; render only reads.
   ((stateful? node)
    (when (and (stateful-init-proc node)
               (not (stateful-initialized? node)))
      ((stateful-init-proc node) node)
      (set-stateful-initialized?! node #t))
    (view->cmds ((stateful-view-proc node) node) rect))
   (else '())))

(define (image-cmd->fallback-cmds cmd)
  (view->cmds (image-fallback cmd)
              (make-rect (image-col cmd) (image-row cmd)
                         (image-w cmd) (image-h cmd))))

(define (bg-fill-cmds face rect)
  (if face
      (list (make-fill (rect-col rect) (rect-row rect)
                       (rect-w rect) (rect-h rect)
                       face))
      '()))

(define (render-vbox node rect)
  (let ((face (vbox-node-face node))
        (children (vbox-node-children node)))
    (append
     (bg-fill-cmds face rect)
     (let loop ((cs children) (row (rect-row rect)) (remaining (rect-h rect)) (acc '()))
       (cond
        ((or (null? cs) (<= remaining 0)) (reverse acc))
        (else
         (let* ((child (car cs))
                (s (view-size child))
                (cw (min (car s) (rect-w rect)))
                (ch (min (cdr s) remaining))
                (sub (make-rect (rect-col rect) row cw ch))
                (cmds (view->cmds child sub)))
           (loop (cdr cs) (+ row ch) (- remaining ch)
                 (append (reverse cmds) acc)))))))))

(define (render-hbox node rect)
  (let ((face (hbox-node-face node))
        (children (hbox-node-children node)))
    (append
     (bg-fill-cmds face rect)
     (let loop ((cs children) (col (rect-col rect)) (remaining (rect-w rect)) (acc '()))
       (cond
        ((or (null? cs) (<= remaining 0)) (reverse acc))
        (else
         (let* ((child (car cs))
                (s (view-size child))
                (cw (min (car s) remaining))
                (ch (min (cdr s) (rect-h rect)))
                (sub (make-rect col (rect-row rect) cw ch))
                (cmds (view->cmds child sub)))
           (loop (cdr cs) (+ col cw) (- remaining cw)
                 (append (reverse cmds) acc)))))))))

(define (splice-title top-mid title)
  "Embed TITLE into the top border. Single space padding on each side;
the border's own glyph runs right up to it (no ┤ ├ bracket sigils).
Falls back to plain TOP-MID if the title wouldn't fit."
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

(define (render-boxed node rect)
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
       (view->cmds (boxed-node-child node) inner-rect))))))

(define (render-pad node rect)
  (let* ((t (pad-node-top node))
         (r (pad-node-right node))
         (b (pad-node-bottom node))
         (l (pad-node-left node))
         (inner (make-rect (+ (rect-col rect) l)
                           (+ (rect-row rect) t)
                           (max 0 (- (rect-w rect) l r))
                           (max 0 (- (rect-h rect) t b)))))
    (append (bg-fill-cmds (pad-node-face node) rect)
            (view->cmds (pad-node-child node) inner))))

(define (render-margin node rect)
  (let* ((t (margin-node-top    node))
         (r (margin-node-right  node))
         (b (margin-node-bottom node))
         (l (margin-node-left   node))
         (inner (make-rect (+ (rect-col rect) l)
                           (+ (rect-row rect) t)
                           (max 0 (- (rect-w rect) l r))
                           (max 0 (- (rect-h rect) t b)))))
    (view->cmds (margin-node-child node) inner)))

(define (render-text-runs node rect)
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
             (cmds (view->cmds run sub)))
        (loop (cdr runs) (+ col w) (append (reverse cmds) acc) (- rem w)))))))

(define (render-align node rect)
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
    (view->cmds child sub)))

(define (render-width node rect)
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
    (view->cmds child sub)))

(define (render-height node rect)
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
    (view->cmds child sub)))
