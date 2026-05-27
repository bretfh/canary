(define-module (canary term render)
  #:use-module (canary term types)
  #:use-module (canary term modes)
  #:use-module (canary width)
  #:use-module (rnrs bytevectors)
  #:export (term-render-line
            term-render-region
            term-dump
            term-dump-row
            term-render-ansi-line
            face->plist
            face->ansi-codes
            emit-sgr-string
            term-diff->ansi))

(define (printable ch)
  "Return CH if it's a printable character, otherwise space.
Control chars (< 32) and DEL (127) collapse to space."
  (let ((code (char->integer ch)))
    (cond
     ((< code 32) #\space)
     ((= code 127) #\space)
     (else ch))))

(define (face->plist face)
  "Return FACE as a property list suitable for inspection or
serialisation, or #f if FACE is #f.  Inverse and conceal are
applied by swapping fg/bg in the result."
  (and face
       (let ((p '()))
         (when (face-bold? face)    (set! p (cons* 'bold #t p)))
         (when (face-faint? face)   (set! p (cons* 'faint #t p)))
         (when (face-italic? face)  (set! p (cons* 'italic #t p)))
         (when (face-underline face) (set! p (cons* 'underline #t p)))
         (when (face-crossed? face) (set! p (cons* 'strike-through #t p)))
         (when (face-inverse? face) (set! p (cons* 'inverse #t p)))
         (let ((fg (face-fg face))
               (bg (face-bg face)))
           (when (face-inverse? face)
             (let ((tmp fg)) (set! fg bg) (set! bg tmp)))
           (when (face-conceal? face)
             (set! fg bg))
           (when fg (set! p (cons* 'fg fg p)))
           (when bg (set! p (cons* 'bg bg p))))
         p)))

(define (term-render-line term y . maybe-buf)
  "Render row Y of TERM.  Returns two values: a string of width
chars (reusing MAYBE-BUF when it's a correctly-sized string) and
a list of (COLUMN FACE-PLIST) entries marking each face change."
  (let* ((w (term-width term))
         (chars (if (and (pair? maybe-buf)
                         (string? (car maybe-buf))
                         (= (string-length (car maybe-buf)) w))
                    (car maybe-buf)
                    (make-string w #\space)))
         (changes '())
         (prev-face #f)
         (first #t))
    (do ((x 0 (+ x 1)))
        ((= x w))
      (let ((ch   (term-char-at term x y))
            (face (term-face-at term x y)))
        (string-set! chars x (printable ch))
        (when (or first (not (face-attrs-equal? face prev-face)))
          (set! changes (cons (list x (face->plist face)) changes))
          (set! prev-face face)
          (set! first #f))))
    (values chars (reverse changes))))

(define (term-render-region term origin)
  "Render the visible grid of TERM as a list of cmd-style entries
('text COL ROW SEGMENT FACE-PLIST) plus an optional final 'cursor
entry, with positions offset by ORIGIN (a (COL ROW) list)."
  (let ((col0 (car origin))
        (row0 (cadr origin))
        (h (term-height term))
        (cmds '()))
    (do ((y 0 (+ y 1)))
        ((= y h))
      (call-with-values
       (lambda () (term-render-line term y))
       (lambda (chars changes)
         (let loop ((cs changes))
           (cond
            ((null? cs) #f)
            (else
             (let* ((entry (car cs))
                    (start (car entry))
                    (face-pl (cadr entry))
                    (next-start
                     (cond
                      ((null? (cdr cs)) (term-width term))
                      (else (car (cadr cs)))))
                    (segment (substring chars start next-start)))
               (set! cmds
                     (cons (list 'text (+ col0 start) (+ row0 y)
                                 segment face-pl)
                           cmds))
               (loop (cdr cs)))))))))
    (when (mode-get (term-modes term) 'cursor-visible)
      (set! cmds
            (cons (list 'cursor
                        (+ col0 (term-cursor-x term))
                        (+ row0 (term-cursor-y term))
                        (cursor-style->draw (term-cursor-style term)))
                  cmds)))
    (reverse cmds)))

(define (cursor-style->draw style)
  "Collapse a (possibly blinking) cursor style symbol to its
non-blinking equivalent for the draw layer."
  (case style
    ((block blinking-block) 'block)
    ((underline blinking-underline) 'underline)
    ((bar blinking-bar) 'bar)
    (else 'block)))

(define (term-dump-row term y)
  "Return row Y of TERM as a visible string: sentinel cells (the
right half of a wide character) are omitted so each wide char
appears once and occupies its natural two display columns."
  (let ((w (term-width term))
        (out (open-output-string)))
    (do ((x 0 (+ x 1)))
        ((= x w) (get-output-string out))
      (let ((ch (term-char-at term x y)))
        (unless (wide-cont? (char->integer ch))
          (display ch out))))))

(define (term-dump term)
  "Return the visible grid of TERM as a single string with rows
separated by newlines."
  (let ((h (term-height term))
        (out (open-output-string)))
    (do ((y 0 (+ y 1)))
        ((= y h))
      (display (term-dump-row term y) out)
      (when (< y (- h 1))
        (newline out)))
    (get-output-string out)))

(define (underline-style-code style)
  "Return the CSI 4:n m sub-parameter sub-code for a non-#f underline
STYLE symbol, or the bare \"4\" code when STYLE is 'single or just #t."
  (case style
    ((single #t) "4")
    ((double)    "4:2")
    ((curly)     "4:3")
    ((dotted)    "4:4")
    ((dashed)    "4:5")
    (else        "4")))

(define (face->ansi-codes face)
  "Return the SGR numeric codes for FACE as a list of strings.
Starts with \"0\" (reset) so the output is self-contained.  Returns
'(\"0\") for a #f face."
  (cond
   ((not face) '("0"))
   (else
    (let ((codes (list "0")))
      (when (face-bold? face)    (set! codes (cons "1" codes)))
      (when (face-faint? face)   (set! codes (cons "2" codes)))
      (when (face-italic? face)  (set! codes (cons "3" codes)))
      (when (face-underline face)
        (set! codes (cons (underline-style-code (face-underline face))
                          codes)))
      (when (face-inverse? face) (set! codes (cons "7" codes)))
      (when (face-crossed? face) (set! codes (cons "9" codes)))
      (when (face-overline? face) (set! codes (cons "53" codes)))
      (let ((fg (if (face-inverse? face) (face-bg face) (face-fg face)))
            (bg (if (face-inverse? face) (face-fg face) (face-bg face)))
            (ul (face-ul-color face)))
        (when (face-conceal? face) (set! fg bg))
        (when fg (set! codes (cons (color-code fg 38) codes)))
        (when bg (set! codes (cons (color-code bg 48) codes)))
        (when ul (set! codes (cons (color-code ul 58) codes))))
      (reverse codes)))))

(define (color-code color base)
  "Return the SGR code string for COLOR relative to BASE (38 for
fg, 48 for bg).  Maps 0-7 to the basic 8 colours, 8-15 to bright
8, 16-255 to indexed-256 (`5;N`), and (R G B) lists to true-colour
(`2;R;G;B`)."
  (cond
   ((and (integer? color) (>= color 0) (<= color 7))
    (number->string (+ (- base 8) color)))
   ((and (integer? color) (>= color 8) (<= color 15))
    (number->string (+ (if (= base 38) 90 100) (- color 8))))
   ((and (integer? color) (>= color 0) (<= color 255))
    (string-append (number->string base) ";5;" (number->string color)))
   ((and (list? color) (= (length color) 3))
    (string-append (number->string base)
                   ";2;"
                   (number->string (car color)) ";"
                   (number->string (cadr color)) ";"
                   (number->string (caddr color))))
   (else (number->string (+ base 1)))))

(define (emit-sgr-string face)
  "Return the ESC[…m SGR sequence representing FACE."
  (string-append (string #\esc) "["
                 (let join ((codes (face->ansi-codes face)))
                   (cond
                    ((null? codes) "")
                    ((null? (cdr codes)) (car codes))
                    (else (string-append (car codes) ";"
                                         (join (cdr codes))))))
                 "m"))

(define (term-render-ansi-line term y)
  "Return row Y of TERM as a self-contained ANSI string: SGR
sequences emitted at each face change, sentinel cells skipped,
trailing ESC[0m reset."
  (let* ((w (term-width term))
         (out (open-output-string))
         (prev-face #f)
         (first #t))
    (do ((x 0 (+ x 1)))
        ((= x w))
      (let ((ch   (term-char-at term x y))
            (face (term-face-at term x y)))
        (unless (wide-cont? (char->integer ch))
          (when (or first (not (face-attrs-equal? face prev-face)))
            (display (emit-sgr-string face) out)
            (set! prev-face face)
            (set! first #f))
          (display (printable ch) out))))
    (display (string-append (string #\esc) "[0m") out)
    (get-output-string out)))

(define (move-to-ansi col row)
  "Return the ESC[r;cH cursor-positioning sequence for 0-indexed
(COL, ROW)."
  (string-append (string #\esc) "["
                 (number->string (+ row 1)) ";"
                 (number->string (+ col 1)) "H"))

(define (face-hyperlink-of fa)
  "Return the hyperlink uri carried by face-attrs FA, or #f if FA is
#f or carries no hyperlink."
  (and fa (face-hyperlink fa)))

(define (face-semantic-of fa)
  "Return the semantic-content tag carried by face-attrs FA, or #f if
FA is #f or carries no tag."
  (and fa (face-semantic fa)))

(define (emit-osc-8 uri out)
  "Display the OSC 8 ANSI sequence opening URI (or closing the
current hyperlink when URI is #f) to OUT."
  (display (string #\esc) out)
  (display "]8;;" out)
  (when uri (display uri out))
  (display (string #\esc) out)
  (display "\\" out))

(define (emit-osc-133 kind out)
  "Display the OSC 133 ANSI marker for KIND ('prompt / 'input /
'output / 'unknown), or 'D' (post-command) when KIND is #f."
  (display (string #\esc) out)
  (display "]133;" out)
  (display (case kind
             ((prompt)  "A")
             ((input)   "B")
             ((output)  "C")
             ((#f)      "D")
             (else      "A"))
           out)
  (display (string #\esc) out)
  (display "\\" out))

(define (diff-cell! cur-chars cur-faces prev-chars prev-faces i x y out state)
  "Emit the ANSI fragment needed to bring cell (X, Y) at flat index
I from PREV to CUR.  STATE is a 6-element vector
#(cursor-x cursor-y last-face any-emitted? last-hyperlink last-semantic)
carrying outgoing emitter state across calls."
  (let ((cur-ch (u32vector-ref cur-chars i))
        (cur-fa (vector-ref cur-faces i)))
    (cond
     ((wide-cont? cur-ch) #f)
     (else
      (let ((same?
             (and prev-chars
                  (= cur-ch (u32vector-ref prev-chars i))
                  (face-attrs-equal? cur-fa (vector-ref prev-faces i)))))
        (unless same?
          (let ((cursor-x (vector-ref state 0))
                (cursor-y (vector-ref state 1))
                (last-face (vector-ref state 2))
                (last-uri      (vector-ref state 4))
                (last-semantic (vector-ref state 5))
                (cur-uri      (face-hyperlink-of cur-fa))
                (cur-semantic (face-semantic-of cur-fa))
                (cw (char-display-width (integer->char cur-ch))))
            (unless (and (eqv? cursor-x x) (eqv? cursor-y y))
              (display (move-to-ansi x y) out)
              (vector-set! state 0 x)
              (vector-set! state 1 y))
            (unless (face-attrs-equal? cur-fa last-face)
              (display (emit-sgr-string cur-fa) out)
              (vector-set! state 2 cur-fa))
            (unless (equal? cur-uri last-uri)
              (emit-osc-8 cur-uri out)
              (vector-set! state 4 cur-uri))
            (unless (eq? cur-semantic last-semantic)
              (emit-osc-133 cur-semantic out)
              (vector-set! state 5 cur-semantic))
            (display (printable (integer->char cur-ch)) out)
            (vector-set! state 0 (+ x (max 1 cw)))
            (vector-set! state 3 #t))))))))

(define (cell-eq? a-chars a-faces a-i b-chars b-faces b-i)
  "Cell at flat index A-I in (A-CHARS, A-FACES) equals cell at B-I in
(B-CHARS, B-FACES)?"
  (and (= (u32vector-ref a-chars a-i) (u32vector-ref b-chars b-i))
       (face-attrs-equal? (vector-ref a-faces a-i) (vector-ref b-faces b-i))))

(define (row-shifted-by? prev cur y dx dy)
  "Row Y of CUR matches PREV's row (y - dy), with each cell sampled at
column (x - dx) from prev.  Source columns out of [0, w) are exempt
(they're the newly-exposed edge).  Source row out of [0, h) → trivially
#t (we'll paint the whole row as new edge later)."
  (let* ((w (term-width cur))
         (src-y (- y dy)))
    (cond
     ((or (< src-y 0) (>= src-y (term-height prev))) #t)
     (else
      (let* ((prev-chars (term-chars prev)) (prev-faces (term-faces prev))
             (cur-chars  (term-chars cur))  (cur-faces  (term-faces cur))
             (xmin (max 0 dx)) (xmax (+ w (min 0 dx)))
             (cur-row-base  (* y     w))
             (prev-row-base (* src-y w)))
        (let lp ((x xmin))
          (cond
           ((>= x xmax) #t)
           ((cell-eq? prev-chars prev-faces (+ prev-row-base (- x dx))
                      cur-chars  cur-faces  (+ cur-row-base  x))
            (lp (+ x 1)))
           (else #f))))))))

(define %min-shift-rows 4)

(define (find-shift-region prev cur dx dy)
  "For shift candidate (dx, dy), classify every row as shift-compatible
or not, then return (cons t b) for the largest contiguous run of
compatible rows — provided it spans at least %min-shift-rows.  Else
#f.  The DECSTBM-scoped scroll fast path operates on rows [t, b]
inclusive; the rows outside that band fall through to cell-by-cell
diff."
  (let* ((h (term-height cur))
         (cls (make-vector h #f)))
    (do ((y 0 (+ y 1))) ((>= y h))
      (vector-set! cls y (row-shifted-by? prev cur y dx dy)))
    (let lp ((y 0) (best-t #f) (best-len 0) (cur-t #f) (cur-len 0))
      (cond
       ((>= y h)
        (let* ((final-t   (if (> cur-len best-len) cur-t best-t))
               (final-len (max cur-len best-len)))
          (cond
           ((and final-t (>= final-len %min-shift-rows))
            (cons final-t (+ final-t final-len -1)))
           (else #f))))
       ((vector-ref cls y)
        (lp (+ y 1) best-t best-len (or cur-t y) (+ cur-len 1)))
       (else
        (cond
         ((> cur-len best-len) (lp (+ y 1) cur-t cur-len #f 0))
         (else                 (lp (+ y 1) best-t best-len #f 0))))))))

(define (detect-shift prev cur)
  "Return (list dx dy t b) for the best cardinal shift whose
compatible-rows run is the longest, or #f if none reaches the
%min-shift-rows threshold.  Diagonals not probed — delve's keymap is
cardinal-only and the player only moves by one per key."
  (and prev
       (= (term-width prev)  (term-width cur))
       (= (term-height prev) (term-height cur))
       (let lp ((cands '((0 . -1) (0 . 1) (-1 . 0) (1 . 0)))
                (best #f) (best-len 0))
         (cond
          ((null? cands) best)
          (else
           (let ((region (find-shift-region prev cur
                                            (caar cands) (cdar cands))))
             (cond
              ((not region) (lp (cdr cands) best best-len))
              (else
               (let ((len (- (cdr region) (car region) -1)))
                 (cond
                  ((> len best-len)
                   (lp (cdr cands)
                       (list (caar cands) (cdar cands)
                             (car region) (cdr region))
                       len))
                  (else
                   (lp (cdr cands) best best-len))))))))))))

(define (paint-edge! cur out state xs ys)
  "Emit cells from CUR at the coords formed by lists XS x YS, with #f
prev so every cell is treated as new."
  (let ((cur-chars (term-chars cur))
        (cur-faces (term-faces cur))
        (w         (term-width cur)))
    (for-each
     (lambda (y)
       (for-each
        (lambda (x)
          (diff-cell! cur-chars cur-faces #f #f
                      (+ (* y w) x) x y out state))
        xs))
     ys)))

(define (iota-range n)
  (let lp ((i 0) (acc '()))
    (cond ((= i n) (reverse acc))
          (else (lp (+ i 1) (cons i acc))))))

(define (iota-list start end)
  "Inclusive START, exclusive END."
  (let lp ((i start) (acc '()))
    (cond ((>= i end) (reverse acc))
          (else (lp (+ i 1) (cons i acc))))))

(define (diff-row! prev-chars prev-faces cur-chars cur-faces w y out state)
  "Cell-by-cell diff of one row Y from prev to cur."
  (let ((row-base (* y w)))
    (do ((x 0 (+ x 1))) ((>= x w))
      (diff-cell! cur-chars cur-faces prev-chars prev-faces
                  (+ row-base x) x y out state))))

(define (shift-diff->ansi prev cur dx dy t b)
  "Slide rows [t, b] by (dx, dy) using terminal scroll/insert/delete,
paint the newly-exposed edge inside that band, then cell-by-cell diff
the rows outside.

For vertical shifts (dy = ±1) we scope the terminal's scroll to
[t, b] via DECSTBM (\\e[<t+1>;<b+1>r) so non-map rows aren't
disturbed, emit \\e[1S or \\e[1T, then restore DECSTBM with \\e[r.
For horizontal shifts (dx = ±1) we emit per-row \\e[1P (delete) or
\\e[1@ (insert) just for rows in [t, b]; DECSTBM isn't relevant
since insert/delete-char only affects the targeted line."
  (let* ((w   (term-width cur))
         (h   (term-height cur))
         (cur-chars  (term-chars cur))  (cur-faces  (term-faces cur))
         (prev-chars (term-chars prev)) (prev-faces (term-faces prev))
         (out   (open-output-string))
         (state (vector #f #f #f #f #f #f)))
    ;; 1. emit the slide
    (cond
     ((or (= dy -1) (= dy 1))
      (display "\x1b[" out)
      (display (number->string (+ t 1)) out)
      (display ";" out)
      (display (number->string (+ b 1)) out)
      (display "r" out)
      (display (if (= dy -1) "\x1b[1S" "\x1b[1T") out)
      (display "\x1b[r" out))
     ((or (= dx -1) (= dx 1))
      (do ((y t (+ y 1))) ((> y b))
        (display (move-to-ansi 0 y) out)
        (display (if (= dx -1) "\x1b[1P" "\x1b[1@") out))))
    ;; cursor moved implicitly; force the next emit to issue a move-to
    (vector-set! state 0 #f)
    (vector-set! state 1 #f)
    ;; 2. paint the newly-exposed edge inside [t, b]
    (cond
     ((= dy -1) (paint-edge! cur out state (iota-range w) (list b)))
     ((= dy 1)  (paint-edge! cur out state (iota-range w) (list t)))
     ((= dx -1) (paint-edge! cur out state (list (- w 1))
                              (iota-list t (+ b 1))))
     ((= dx 1)  (paint-edge! cur out state (list 0)
                              (iota-list t (+ b 1)))))
    ;; 3. cell-by-cell diff the rows outside [t, b]
    (do ((y 0 (+ y 1))) ((>= y h))
      (when (or (< y t) (> y b))
        (diff-row! prev-chars prev-faces cur-chars cur-faces w y out state)))
    ;; 4. trailing reset + cursor park
    (when (vector-ref state 3)
      (when (vector-ref state 4) (emit-osc-8 #f out))
      (display (string-append (string #\esc) "[0m") out))
    (when (mode-get (term-modes cur) 'cursor-visible)
      (display (move-to-ansi (term-cursor-x cur) (term-cursor-y cur)) out))
    (get-output-string out)))

(define (full-diff->ansi prev cur)
  "Cell-by-cell diff fallback — used when there's no prev, sizes
differ, or no cardinal shift matches."
  (let* ((w (term-width cur))
         (h (term-height cur))
         (cur-chars (term-chars cur))
         (cur-faces (term-faces cur))
         (use-prev? (and prev
                         (= (term-width prev) w)
                         (= (term-height prev) h)))
         (prev-chars (if use-prev? (term-chars prev) #f))
         (prev-faces (if use-prev? (term-faces prev) #f))
         (out (open-output-string))
         (state (vector #f #f #f #f #f #f)))
    (let loop-y ((y 0))
      (when (< y h)
        (let ((row-base (* y w)))
          (let loop-x ((x 0))
            (when (< x w)
              (diff-cell! cur-chars cur-faces prev-chars prev-faces
                          (+ row-base x) x y out state)
              (loop-x (+ x 1)))))
        (loop-y (+ y 1))))
    (when (vector-ref state 3)
      (when (vector-ref state 4) (emit-osc-8 #f out))
      (display (string-append (string #\esc) "[0m") out))
    (when (mode-get (term-modes cur) 'cursor-visible)
      (display (move-to-ansi (term-cursor-x cur) (term-cursor-y cur)) out))
    (get-output-string out)))

(define (term-diff->ansi prev cur)
  "Return an ANSI string that transforms a terminal displaying PREV
into one displaying CUR.  Tries a row-scoped cardinal-shift fast path
first (emits DECSTBM-scoped scroll / insert / delete + paints the
newly-exposed edge inside the matched band — O(w+h) bytes for the
map region — and cell-by-cell diffs the rows outside that band, so
non-scrolling chrome like status / hotbar / hint strips paint
normally).  Falls back to whole-frame cell-by-cell diff when no
cardinal direction yields a band of at least %min-shift-rows."
  (cond
   ((detect-shift prev cur) =>
    (lambda (shift)
      (shift-diff->ansi prev cur
                        (car shift) (cadr shift)
                        (caddr shift) (cadddr shift))))
   (else (full-diff->ansi prev cur))))
