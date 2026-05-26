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
      (when (face-underline face) (set! codes (cons "4" codes)))
      (when (face-inverse? face) (set! codes (cons "7" codes)))
      (when (face-crossed? face) (set! codes (cons "9" codes)))
      (let ((fg (if (face-inverse? face) (face-bg face) (face-fg face)))
            (bg (if (face-inverse? face) (face-fg face) (face-bg face))))
        (when (face-conceal? face) (set! fg bg))
        (when fg (set! codes (cons (color-code fg 38) codes)))
        (when bg (set! codes (cons (color-code bg 48) codes))))
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

(define (diff-cell! cur-chars cur-faces prev-chars prev-faces i x y out state)
  "Emit the ANSI fragment needed to bring cell (X, Y) at flat index
I from PREV to CUR.  STATE is a 4-element vector
#(cursor-x cursor-y last-face any-emitted?) carrying outgoing
emitter state across calls.  Sentinel cells emit nothing; equal
cells emit nothing; differing cells emit a cursor move (if not
already there), an SGR change (if the face differs), and the char."
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
                (cw (char-display-width (integer->char cur-ch))))
            (unless (and (eqv? cursor-x x) (eqv? cursor-y y))
              (display (move-to-ansi x y) out)
              (vector-set! state 0 x)
              (vector-set! state 1 y))
            (unless (face-attrs-equal? cur-fa last-face)
              (display (emit-sgr-string cur-fa) out)
              (vector-set! state 2 cur-fa))
            (display (printable (integer->char cur-ch)) out)
            (vector-set! state 0 (+ x (max 1 cw)))
            (vector-set! state 3 #t))))))))

(define (term-diff->ansi prev cur)
  "Return an ANSI string that transforms a terminal displaying PREV
into one displaying CUR.  When PREV is #f or differs in size, the
output is a full repaint (every cell emitted)."
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
         (state (vector #f #f #f #f)))
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
      (display (string-append (string #\esc) "[0m") out))
    (when (mode-get (term-modes cur) 'cursor-visible)
      (display (move-to-ansi (term-cursor-x cur) (term-cursor-y cur)) out))
    (get-output-string out)))
