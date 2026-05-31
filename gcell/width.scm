(define-module (gcell width)
  #:export (char-display-width
            string-display-width
            string-display-clamp))

(define (char-display-width ch)
  "Return the column width of CH on a terminal: 0 for combining marks
and other zero-width chars, 2 for East-Asian Wide / Fullwidth / emoji,
1 otherwise. Approximate — does not cover every Unicode block but
handles the common 90%."
  (let ((code (char->integer ch)))
    (cond
     ((< code #x20) 0)
     ((= code #x7F) 0)
     ((or (and (<= #x0300 code) (<= code #x036F))   ; combining diacritical
          (and (<= #x0483 code) (<= code #x0489))   ; cyrillic combining
          (and (<= #x0591 code) (<= code #x05C7))   ; hebrew
          (and (<= #x064B code) (<= code #x065F))   ; arabic
          (and (<= #x200B code) (<= code #x200F))   ; zero-width / RTL marks
          (and (<= #x20D0 code) (<= code #x20FF))   ; combining for symbols
          (and (<= #xFE00 code) (<= code #xFE0F))   ; variation selectors
          (and (<= #xFE20 code) (<= code #xFE2F))   ; combining half marks
          (=  code #xFEFF))                          ; BOM
      0)
     ((or (and (<= #x1100 code) (<= code #x115F))   ; hangul jamo
          (and (<= #x2E80 code) (<= code #x2FFF))   ; CJK radicals etc.
          (and (<= #x3000 code) (<= code #x9FFF))   ; CJK
          (and (<= #xA000 code) (<= code #xA4CF))   ; Yi
          (and (<= #xAC00 code) (<= code #xD7A3))   ; hangul syllables
          (and (<= #xF900 code) (<= code #xFAFF))   ; CJK compat
          (and (<= #xFE30 code) (<= code #xFE4F))   ; CJK compat forms
          (and (<= #xFF01 code) (<= code #xFF60))   ; fullwidth
          (and (<= #xFFE0 code) (<= code #xFFE6))   ; fullwidth signs
          (and (<= #x1F300 code) (<= code #x1F9FF)) ; emoji misc + symbols
          (and (<= #x1FA70 code) (<= code #x1FAFF)) ; more emoji
          (and (<= #x20000 code) (<= code #x2FFFD)) ; CJK ext B+
          (and (<= #x30000 code) (<= code #x3FFFD))); CJK ext G
      2)
     (else 1))))

(define (string-display-width s)
  "Sum of column widths for every char in S."
  (let ((n (string-length s)))
    (let lp ((i 0) (acc 0))
      (cond
       ((= i n) acc)
       (else (lp (+ i 1) (+ acc (char-display-width (string-ref s i)))))))))

(define (string-display-clamp s max-w)
  "Return the longest prefix of S whose total display width is ≤ MAX-W.
Stops before a wide char that would overflow rather than splitting it."
  (cond
   ((<= max-w 0) "")
   (else
    (let ((n (string-length s)))
      (let lp ((i 0) (acc 0))
        (cond
         ((= i n) s)
         (else
          (let ((cw (char-display-width (string-ref s i))))
            (cond
             ((> (+ acc cw) max-w) (substring s 0 i))
             (else (lp (+ i 1) (+ acc cw))))))))))))
