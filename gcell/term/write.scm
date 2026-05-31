(define-module (gcell term write)
  #:use-module (gcell term types)
  #:use-module (gcell term ops)
  #:use-module (gcell term modes)
  #:use-module (gcell width)
  #:export (term-write!)
  #:re-export (char-display-width))

(define *dec-line-drawing*
  (let ((h (make-hash-table)))
    (for-each (lambda (pair)
                (hash-set! h (car pair) (cdr pair)))
              '((#\+ . #\→) (#\, . #\←) (#\- . #\↑) (#\. . #\↓)
                (#\0 . #\█) (#\` . #\◆) (#\a . #\▒) (#\f . #\°)
                (#\g . #\±) (#\h . #\░) (#\i . #\#)
                (#\j . #\┘) (#\k . #\┐) (#\l . #\┌) (#\m . #\└)
                (#\n . #\┼) (#\o . #\⎺) (#\p . #\⎻) (#\q . #\─)
                (#\r . #\⎼) (#\s . #\⎽) (#\t . #\├) (#\u . #\┤)
                (#\v . #\┴) (#\w . #\┬) (#\x . #\│) (#\y . #\≤)
                (#\z . #\≥) (#\{ . #\π) (#\| . #\≠) (#\} . #\£)
                (#\~ . #\•)))
    h))

(define (translate-charset ch charset)
  "Map character CH through the active CHARSET designation.  Only
'dec-line-drawing translates; other charsets pass CH through."
  (case charset
    ((dec-line-drawing)
     (or (hash-ref *dec-line-drawing* ch) ch))
    (else ch)))

(define (current-charset-mapping term)
  "Return the charset symbol currently designated to TERM's active
slot (G0/G1/G2/G3)."
  (case (term-active-charset term)
    ((g0) (term-g0 term))
    ((g1) (term-g1 term))
    ((g2) (term-g2 term))
    ((g3) (term-g3 term))
    (else 'us-ascii)))


(define (current-write-face term)
  "Return TERM's current face attrs as a stable, snapshotted copy.
Reuses the cached snapshot when attrs haven't changed since last
write; otherwise copies and caches.  Lets downstream cell writes
share face identity by `eq?`."
  (let ((cur (term-attrs term))
        (cached (term-last-write-face term)))
    (if (and cached (face-attrs-equal? cached cur))
        cached
        (let ((c (copy-face-attrs cur)))
          (set-term-last-write-face! term c)
          c))))

(define (consume-pending-wrap! term)
  "If TERM has the pending-wrap flag set, clear it.  When auto-margin
is enabled, also wrap to column 0 of the next row, scrolling the
scroll region at the bottom.  Honours the spec rule that printing at
the last column sets a flag rather than advancing the cursor; the
next print consumes the flag."
  (when (term-pending-wrap? term)
    (set-term-pending-wrap! term #f)
    (when (mode-get (term-modes term) 'autowrap)
      (set-term-cursor-x! term 0)
      (cond
       ((= (term-cursor-y term) (term-scroll-bottom term))
        (term-scroll-up! term 1))
       (else
        (set-term-cursor-y! term (+ (term-cursor-y term) 1)))))))

(define (advance-after-write! term x cw)
  "Advance TERM's cursor after writing a char of display width CW at
column X.  If the advance would step past the right edge, leave the
cursor at the last column and set the pending-wrap flag instead of
walking off the grid."
  (let ((w (term-width term)))
    (cond
     ((>= (+ x cw) w)
      (set-term-cursor-x! term (- w 1))
      (set-term-pending-wrap! term #t))
     (else
      (set-term-cursor-x! term (+ x cw))))))

(define* (term-write! term str #:optional (start 0) (end #f))
  "Write the substring of STR from START to END (default whole STR)
to TERM at the current cursor, advancing the cursor and honouring
auto-margin, insert mode, charset translation, and wide-character
sentinel placement.  Zero-width chars are skipped; wide chars
occupy two cells with a sentinel in the second.  Printing at the
last column sets the pending-wrap flag; the next character honours
it (wrapping when auto-margin is on, overwriting otherwise)."
  (let* ((end (or end (string-length str)))
         (charset (current-charset-mapping term))
         (face (current-write-face term)))
    (let loop ((idx start))
      (when (< idx end)
        (let* ((raw (string-ref str idx))
               (ch (translate-charset raw charset))
               (cw (char-display-width ch)))
          (unless (zero? cw)
            (consume-pending-wrap! term)
            (set-term-last-char! term ch)
            (when (mode-get (term-modes term) 'insert)
              (term-insert-char! term cw))
            (let ((x (term-cursor-x term))
                  (y (term-cursor-y term))
                  (w (term-width term)))
              (cond
               ((and (= cw 2) (>= (+ x 1) w))
                (set-term-cell-at! term x y #\space face)
                (set-term-cursor-x! term 0)
                (cond
                 ((= y (term-scroll-bottom term))
                  (term-scroll-up! term 1))
                 (else
                  (set-term-cursor-y! term (+ y 1))))
                (let ((x2 (term-cursor-x term))
                      (y2 (term-cursor-y term)))
                  (set-term-cell-at! term x2 y2 ch face)
                  (when (< (+ x2 1) w)
                    (set-term-cell-at! term (+ x2 1) y2
                                       (integer->char +wide-cont+) face))
                  (advance-after-write! term x2 cw)))
               (else
                (set-term-cell-at! term x y ch face)
                (when (and (= cw 2) (< (+ x 1) w))
                  (set-term-cell-at! term (+ x 1) y
                                     (integer->char +wide-cont+) face))
                (advance-after-write! term x cw)))))
          (loop (+ idx 1)))))))
