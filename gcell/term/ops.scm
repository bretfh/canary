(define-module (gcell term ops)
  #:use-module (gcell term types)
  #:use-module (rnrs bytevectors)
  #:export (term-cursor-up!
            term-cursor-down!
            term-cursor-left!
            term-cursor-right!
            term-cursor-horizontal-abs!
            term-cursor-vertical-abs!
            term-goto!
            term-save-cursor!
            term-restore-cursor!
            term-erase-in-line!
            term-erase-in-display!
            term-erase-char!
            term-insert-char!
            term-delete-char!
            term-insert-line!
            term-delete-line!
            term-scroll-up!
            term-scroll-down!
            term-horizontal-tab!
            term-horizontal-backtab!
            term-index!
            term-reverse-index!
            term-line-feed!
            term-carriage-return!
            term-set-scroll-region!
            term-enter-alt-screen!
            term-exit-alt-screen!
            term-current-bg-face))

(define (clamp-min v lo)
  "Return V if V ≥ LO, otherwise LO."
  (if (< v lo) lo v))

(define* (term-cursor-right! term #:optional (n 1))
  "Move TERM's cursor right by N cells, clamped to the rightmost
column.  Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (let ((n (clamp-min n 1))
        (max-x (- (term-width term) 1)))
    (set-term-cursor-x! term (min (+ (term-cursor-x term) n) max-x))))

(define* (term-cursor-left! term #:optional (n 1))
  "Move TERM's cursor left by N cells, clamped to column 0.  Clears
the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (let ((n (clamp-min n 1)))
    (set-term-cursor-x! term (max (- (term-cursor-x term) n) 0))))

(define* (term-cursor-down! term #:optional (n 1))
  "Move TERM's cursor down by N cells, clamped to the bottom row.
Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (let ((n (clamp-min n 1))
        (max-y (- (term-height term) 1)))
    (set-term-cursor-y! term (min (+ (term-cursor-y term) n) max-y))))

(define* (term-cursor-up! term #:optional (n 1))
  "Move TERM's cursor up by N cells, clamped to row 0.  Clears the
pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (let ((n (clamp-min n 1)))
    (set-term-cursor-y! term (max (- (term-cursor-y term) n) 0))))

(define* (term-cursor-horizontal-abs! term #:optional (n 1))
  "Position TERM's cursor at 1-indexed column N (clamped to grid).
Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (set-term-cursor-x! term (min (max (- n 1) 0) (- (term-width term) 1))))

(define* (term-cursor-vertical-abs! term #:optional (n 1))
  "Position TERM's cursor at 1-indexed row N (clamped to grid).
Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (set-term-cursor-y! term (min (max (- n 1) 0) (- (term-height term) 1))))

(define* (term-goto! term #:optional (y 1) (x 1))
  "Position TERM's cursor at 1-indexed (X, Y), clamped to grid.
Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (set-term-cursor-y! term (min (max (- (or y 1) 1) 0) (- (term-height term) 1)))
  (set-term-cursor-x! term (min (max (- (or x 1) 1) 0) (- (term-width term) 1))))

(define (term-save-cursor! term)
  "Snapshot TERM's cursor position, pending-wrap flag, and attribute
state into the save slots, restorable via `term-restore-cursor!`."
  (set-term-saved-cursor-x! term (term-cursor-x term))
  (set-term-saved-cursor-y! term (term-cursor-y term))
  (set-term-saved-pending-wrap! term (term-pending-wrap? term))
  (set-term-saved-attrs! term (copy-face-attrs (term-attrs term))))

(define (term-restore-cursor! term)
  "Restore TERM's cursor position, pending-wrap flag, and attribute
state from the slots saved by `term-save-cursor!`.  No-op if nothing
was saved."
  (set-term-cursor-x! term (term-saved-cursor-x term))
  (set-term-cursor-y! term (term-saved-cursor-y term))
  (set-term-pending-wrap! term (term-saved-pending-wrap? term))
  (let ((saved (term-saved-attrs term)))
    (when saved
      (let ((cur (term-attrs term)))
        (set-face-fg! cur (face-fg saved))
        (set-face-bg! cur (face-bg saved))
        (set-face-bold! cur (face-bold? saved))
        (set-face-faint! cur (face-faint? saved))
        (set-face-italic! cur (face-italic? saved))
        (set-face-underline! cur (face-underline saved))
        (set-face-ul-color! cur (face-ul-color saved))
        (set-face-blink! cur (face-blink saved))
        (set-face-inverse! cur (face-inverse? saved))
        (set-face-conceal! cur (face-conceal? saved))
        (set-face-crossed! cur (face-crossed? saved))))))

(define (term-current-bg-face term)
  "Return TERM's current face if it has a non-default background,
otherwise #f.  Reuses the write-face cache so erase cmds share face
identity with adjacent writes."
  (and (face-bg (term-attrs term))
       (let ((cur (term-attrs term))
             (cached (term-last-write-face term)))
         (if (and cached (face-attrs-equal? cached cur))
             cached
             (let ((c (copy-face-attrs cur)))
               (set-term-last-write-face! term c)
               c)))))

(define %space (char->integer #\space))

(define (fill-cells! chars faces start end face)
  "Fill cells [START, END) of CHARS / FACES with spaces and FACE."
  (do ((i start (+ i 1)))
      ((= i end))
    (u32vector-set! chars i %space)
    (vector-set!    faces i face)))

(define* (term-erase-in-line! term #:optional (mode 0))
  "Erase part of the cursor's row.  MODE 0 erases from cursor to
end of line (default), 1 erases from start of line to cursor, 2
erases the whole line.  Erased cells take the current bg face."
  (let* ((y (term-cursor-y term))
         (x (term-cursor-x term))
         (w (term-width term))
         (chars (term-chars term))
         (faces (term-faces term))
         (base (* y w))
         (face (term-current-bg-face term)))
    (case mode
      ((0) (fill-cells! chars faces (+ base x) (+ base w) face))
      ((1) (fill-cells! chars faces base (+ base x 1) face))
      ((2) (fill-cells! chars faces base (+ base w) face)))))

(define* (term-erase-in-display! term #:optional (mode 0))
  "Erase part of the display.  MODE 0 erases from cursor to end of
screen (default), 1 erases from start of screen to cursor, 2
erases the whole screen, 3 also clears scrollback."
  (let* ((y (term-cursor-y term))
         (h (term-height term))
         (w (term-width term))
         (chars (term-chars term))
         (faces (term-faces term))
         (face  (term-current-bg-face term)))
    (case mode
      ((0)
       (term-erase-in-line! term 0)
       (fill-cells! chars faces (* (+ y 1) w) (* h w) face))
      ((1)
       (fill-cells! chars faces 0 (* y w) face)
       (term-erase-in-line! term 1))
      ((2 3)
       (term-clear! term face)
       (when (= mode 3)
         (set-term-scrollback-size! term 0))))))

(define* (term-erase-char! term #:optional (n 1))
  "Replace N cells starting at the cursor with spaces in the
current bg face.  Cursor position unchanged.  Clamped to row width."
  (let* ((n (clamp-min n 1))
         (y (term-cursor-y term))
         (x (term-cursor-x term))
         (w (term-width term))
         (chars (term-chars term))
         (faces (term-faces term))
         (count (min n (- w x)))
         (face (term-current-bg-face term))
         (base (* y w)))
    (fill-cells! chars faces (+ base x) (+ base x count) face)))

(define (shift-row! chars faces base from to count)
  "Within one row at offset BASE, copy COUNT cells from FROM to TO. Handles overlap."
  (cond
   ((= from to) #f)
   ((< from to)
    (do ((i (- count 1) (- i 1)))
        ((< i 0))
      (let ((si (+ base from i))
            (di (+ base to   i)))
        (u32vector-set! chars di (u32vector-ref chars si))
        (vector-set!    faces di (vector-ref    faces si)))))
   (else
    (do ((i 0 (+ i 1)))
        ((= i count))
      (let ((si (+ base from i))
            (di (+ base to   i)))
        (u32vector-set! chars di (u32vector-ref chars si))
        (vector-set!    faces di (vector-ref    faces si)))))))

(define* (term-insert-char! term #:optional (n 1))
  "Insert N blank cells at the cursor, shifting existing cells right
within the row and dropping any that fall off the right edge."
  (let* ((n (clamp-min n 1))
         (y (term-cursor-y term))
         (x (term-cursor-x term))
         (w (term-width term))
         (count (min n (- w x)))
         (face (term-current-bg-face term))
         (chars (term-chars term))
         (faces (term-faces term))
         (base (* y w))
         (move-count (- w x count)))
    (when (positive? move-count)
      (shift-row! chars faces base x (+ x count) move-count))
    (fill-cells! chars faces (+ base x) (+ base x count) face)))

(define* (term-delete-char! term #:optional (n 1))
  "Delete N cells at the cursor, shifting following cells in the
row left and filling the vacated right edge with bg-face spaces."
  (let* ((n (clamp-min n 1))
         (y (term-cursor-y term))
         (x (term-cursor-x term))
         (w (term-width term))
         (count (min n (- w x)))
         (face (term-current-bg-face term))
         (chars (term-chars term))
         (faces (term-faces term))
         (base (* y w))
         (move-count (- w x count)))
    (when (positive? move-count)
      (shift-row! chars faces base (+ x count) x move-count))
    (fill-cells! chars faces (+ base (- w count)) (+ base w) face)))

(define (snapshot-row term y)
  "Return a fresh (chars . faces) pair holding a copy of row Y of
TERM.  Used by scrollback before a row is scrolled off."
  (let* ((w (term-width term))
         (chars (term-chars term))
         (faces (term-faces term))
         (base (* y w))
         (cs (make-u32vector w))
         (fs (make-vector w #f)))
    (do ((i 0 (+ i 1)))
        ((= i w))
      (u32vector-set! cs i (u32vector-ref chars (+ base i)))
      (vector-set!    fs i (vector-ref    faces (+ base i))))
    (cons cs fs)))

(define (push-scrollback! term y)
  "Push a snapshot of row Y onto TERM's scrollback ring.  Grows the
ring up to max-scrollback; drops the push silently when full or
when scrollback is disabled."
  (let ((sb (term-scrollback term))
        (max-sb (term-max-scrollback term)))
    (when (and sb (positive? max-sb))
      (when (>= (term-scrollback-size term) (vector-length sb))
        (let* ((cap (vector-length sb))
               (new-cap (min (* 2 (max cap 64)) max-sb))
               (new (make-vector new-cap #f)))
          (do ((i 0 (+ i 1)))
              ((= i (term-scrollback-size term)))
            (vector-set! new i (vector-ref sb i)))
          (set-term-scrollback! term new)
          (set! sb new)))
      (when (< (term-scrollback-size term) max-sb)
        (vector-set! sb (term-scrollback-size term) (snapshot-row term y))
        (set-term-scrollback-size! term (+ (term-scrollback-size term) 1))))))

(define (copy-line! term src-y dst-y)
  "Copy row SRC-Y of TERM over row DST-Y in place."
  (term-copy-row! term src-y dst-y))

(define* (term-scroll-up! term #:optional (n 1))
  "Scroll the scroll region up by N rows: rows shift toward the
top, the bottom N rows clear.  When scrolling at the top of the
main screen, pushes the displaced rows onto scrollback."
  (let* ((n (clamp-min n 1))
         (top (term-scroll-top term))
         (bot (term-scroll-bottom term))
         (region-height (+ 1 (- bot top)))
         (count (min n region-height)))
    (when (positive? count)
      (when (and (zero? top) (not (term-in-alt? term)))
        (do ((i 0 (+ i 1)))
            ((= i count))
          (push-scrollback! term (+ top i))))
      (do ((y top (+ y 1)))
          ((> y (- bot count)))
        (copy-line! term (+ y count) y))
      (do ((y (max top (- bot count -1)) (+ y 1)))
          ((> y bot))
        (term-clear-row! term y)))))

(define* (term-scroll-down! term #:optional (n 1))
  "Scroll the scroll region down by N rows: rows shift toward the
bottom, the top N rows clear.  No scrollback effect."
  (let* ((n (clamp-min n 1))
         (top (term-scroll-top term))
         (bot (term-scroll-bottom term))
         (region-height (+ 1 (- bot top)))
         (count (min n region-height)))
    (when (positive? count)
      (do ((y bot (- y 1)))
          ((< y (+ top count)))
        (copy-line! term (- y count) y))
      (do ((y top (+ y 1)))
          ((>= y (+ top count)))
        (term-clear-row! term y)))))

(define* (term-insert-line! term #:optional (n 1))
  "Insert N blank lines at the cursor's row within the scroll region.
Pushes lines below it down; lines pushed past the region's bottom
are dropped."
  (let ((n (clamp-min n 1))
        (y (term-cursor-y term))
        (top (term-scroll-top term))
        (bot (term-scroll-bottom term)))
    (when (and (>= y top) (<= y bot))
      (let ((old-top top))
        (set-term-scroll-top! term y)
        (term-scroll-down! term (min n (+ 1 (- bot y))))
        (set-term-scroll-top! term old-top)))))

(define* (term-delete-line! term #:optional (n 1))
  "Delete N lines at the cursor's row within the scroll region.
Lines below it shift up; the bottom N lines of the region clear."
  (let ((n (clamp-min n 1))
        (y (term-cursor-y term))
        (top (term-scroll-top term))
        (bot (term-scroll-bottom term)))
    (when (and (>= y top) (<= y bot))
      (let ((old-top top))
        (set-term-scroll-top! term y)
        (term-scroll-up! term (min n (+ 1 (- bot y))))
        (set-term-scroll-top! term old-top)))))

(define* (term-horizontal-tab! term #:optional (n 1))
  "Advance the cursor by N tab stops (every 8 columns), clamped to
the rightmost column.  Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (let* ((n (clamp-min n 1))
         (x (term-cursor-x term))
         (w (term-width term))
         (next-tab (+ x (- 8 (modulo x 8)))))
    (do ((i 1 (+ i 1)))
        ((= i n))
      (set! next-tab (+ next-tab 8)))
    (set-term-cursor-x! term (min next-tab (- w 1)))))

(define* (term-horizontal-backtab! term #:optional (n 1))
  "Retreat the cursor by N tab stops (every 8 columns), clamped to
column 0.  Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (let* ((n (clamp-min n 1))
         (x (term-cursor-x term))
         (prev-tab (if (zero? (modulo x 8))
                       (- x 8)
                       (- x (modulo x 8)))))
    (do ((i 1 (+ i 1)))
        ((= i n))
      (set! prev-tab (- prev-tab 8)))
    (set-term-cursor-x! term (max prev-tab 0))))

(define (term-index! term)
  "Move the cursor down one row; at the scroll bottom, scroll up
instead.  Column unchanged.  Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (let ((y (term-cursor-y term))
        (bot (term-scroll-bottom term)))
    (cond
     ((= y bot) (term-scroll-up! term 1))
     ((< y (- (term-height term) 1))
      (set-term-cursor-y! term (+ y 1))))))

(define (term-reverse-index! term)
  "Move the cursor up one row; at the scroll top, scroll down
instead.  Column unchanged.  Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (let ((y (term-cursor-y term))
        (top (term-scroll-top term)))
    (cond
     ((= y top) (term-scroll-down! term 1))
     ((> y 0)
      (set-term-cursor-y! term (- y 1))))))

(define (term-line-feed! term)
  "CR+LF: reset cursor to column 0 and advance one row, scrolling
at the bottom of the scroll region.  Clears the pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (let* ((y (term-cursor-y term))
         (bot (term-scroll-bottom term)))
    (set-term-cursor-x! term 0)
    (cond
     ((= y bot) (term-scroll-up! term 1))
     ((< y (- (term-height term) 1))
      (set-term-cursor-y! term (+ y 1))))))

(define (term-carriage-return! term)
  "Reset the cursor to column 0 of its current row.  Clears the
pending-wrap flag."
  (set-term-pending-wrap! term #f)
  (set-term-cursor-x! term 0))

(define* (term-set-scroll-region! term #:optional top bottom)
  "Set the scroll region to 1-indexed rows TOP through BOTTOM
(inclusive) and home the cursor.  Ignored if the range is invalid;
TOP defaults to 1 and BOTTOM to the terminal height."
  (let ((tv (or top 1))
        (bv (or bottom (term-height term))))
    (when (and (< 0 tv) (< tv bv) (<= bv (term-height term)))
      (set-term-scroll-top! term (- tv 1))
      (set-term-scroll-bottom! term (- bv 1))
      (term-goto! term 1 1))))

(define (term-enter-alt-screen! term)
  "Switch TERM into the alternate screen: stash main chars/faces,
allocate fresh blank buffers, and home the cursor.  No-op if
already in the alt screen."
  (unless (term-in-alt? term)
    (let* ((w (term-width term))
           (h (term-height term))
           (n (* w h)))
      (set-term-main-chars! term (term-chars term))
      (set-term-main-faces! term (term-faces term))
      (set-term-chars! term (make-u32vector n %space))
      (set-term-faces! term (make-vector n #f))
      (set-term-in-alt! term #t)
      (term-goto! term 1 1))))

(define (term-exit-alt-screen! term)
  "Switch TERM back to the main screen: restore the stashed main
chars/faces and drop the alt buffers.  No-op if not in the alt
screen."
  (when (term-in-alt? term)
    (set-term-chars! term (term-main-chars term))
    (set-term-faces! term (term-main-faces term))
    (set-term-main-chars! term #f)
    (set-term-main-faces! term #f)
    (set-term-in-alt! term #f)))
