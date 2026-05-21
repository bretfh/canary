(define-module (canary term write)
  #:use-module (canary term types)
  #:use-module (canary term ops)
  #:use-module (canary width)
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
  (case charset
    ((dec-line-drawing)
     (or (hash-ref *dec-line-drawing* ch) ch))
    (else ch)))

(define (current-charset-mapping term)
  (case (term-active-charset term)
    ((g0) (term-g0 term))
    ((g1) (term-g1 term))
    ((g2) (term-g2 term))
    ((g3) (term-g3 term))
    (else 'us-ascii)))


(define (current-write-face term)
  (let ((cur (term-attrs term))
        (cached (term-last-write-face term)))
    (if (and cached (face-attrs-equal? cached cur))
        cached
        (let ((c (copy-face-attrs cur)))
          (set-term-last-write-face! term c)
          c))))

(define* (term-write! term str #:optional (start 0) (end #f))
  (let* ((end (or end (string-length str)))
         (w (term-width term))
         (charset (current-charset-mapping term))
         (face (current-write-face term)))
    (let loop ((idx start))
      (when (< idx end)
        (let* ((raw (string-ref str idx))
               (ch (translate-charset raw charset))
               (cw (char-display-width ch)))
          (unless (zero? cw)
            (set-term-last-char! term ch)
            (when (term-insert? term)
              (term-insert-char! term cw))
            (when (>= (term-cursor-x term) w)
              (cond
               ((term-auto-margin? term)
                (set-term-cursor-x! term 0)
                (cond
                 ((= (term-cursor-y term) (term-scroll-bottom term))
                  (term-scroll-up! term 1))
                 (else
                  (set-term-cursor-y! term (+ (term-cursor-y term) 1)))))
               (else
                (set-term-cursor-x! term (- w 1)))))
            (let ((x (term-cursor-x term))
                  (y (term-cursor-y term)))
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
                  (when (and (= cw 2) (< (+ x2 1) w))
                    (set-term-cell-at! term (+ x2 1) y2
                                       (integer->char +wide-cont+) face))
                  (set-term-cursor-x! term (+ x2 cw))))
               (else
                (set-term-cell-at! term x y ch face)
                (when (and (= cw 2) (< (+ x 1) w))
                  (set-term-cell-at! term (+ x 1) y
                                     (integer->char +wide-cont+) face))
                (set-term-cursor-x! term (+ x cw))))))
          (loop (+ idx 1)))))))
