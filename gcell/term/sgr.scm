(define-module (gcell term sgr)
  #:use-module (gcell term types)
  #:export (process-sgr!))

(define (process-sgr! term params)
  "Apply an SGR (Select Graphic Rendition) sequence with numeric
PARAMS to TERM's attribute slot.  Handles the standard codes 0-9 +
21-29 (reset / weight / underline / blink / inverse / conceal /
strike), 30-37/40-47/90-97/100-107 (16-colour fg/bg), 38/48/58
followed by 5;N or 2;R;G;B (extended colour for fg/bg/underline),
and 39/49/59 (default colour).  Empty params reset all attrs."
  (let* ((attrs (term-attrs term))
         (vec (list->vector params))
         (len (vector-length vec))
         (i 0))
    (define (peek)
      (and (< i len) (vector-ref vec i)))
    (define (next)
      (if (< i len)
          (let ((v (vector-ref vec i)))
            (set! i (+ i 1))
            v)
          #f))
    (cond
     ((zero? len)
      (reset-face-attrs! attrs))
     (else
      (let loop ()
        (when (< i len)
          (let ((code (or (next) 0)))
            (cond
             ((pair? code) (handle-sub-param! code attrs))
             ((eq? code 0) (reset-face-attrs! attrs))
             ((eq? code 1) (set-face-bold! attrs #t)
                           (set-face-faint! attrs #f))
             ((eq? code 2) (set-face-faint! attrs #t)
                           (set-face-bold! attrs #f))
             ((eq? code 3) (set-face-italic! attrs #t))
             ((eq? code 4) (set-face-underline! attrs 'single))
             ((eq? code 5) (set-face-blink! attrs 'slow))
             ((eq? code 6) (set-face-blink! attrs 'fast))
             ((eq? code 7) (set-face-inverse! attrs #t))
             ((eq? code 8) (set-face-conceal! attrs #t))
             ((eq? code 9) (set-face-crossed! attrs #t))
             ((eq? code 21) (set-face-underline! attrs 'double))
             ((eq? code 22) (set-face-bold! attrs #f)
                            (set-face-faint! attrs #f))
             ((eq? code 23) (set-face-italic! attrs #f))
             ((eq? code 24) (set-face-underline! attrs #f))
             ((eq? code 25) (set-face-blink! attrs #f))
             ((eq? code 27) (set-face-inverse! attrs #f))
             ((eq? code 28) (set-face-conceal! attrs #f))
             ((eq? code 29) (set-face-crossed! attrs #f))
             ((eq? code 39) (set-face-fg! attrs #f))
             ((eq? code 49) (set-face-bg! attrs #f))
             ((eq? code 53) (set-face-overline! attrs #t))
             ((eq? code 55) (set-face-overline! attrs #f))
             ((eq? code 59) (set-face-ul-color! attrs #f))
             ((and (>= code 30) (<= code 37))
              (set-face-fg! attrs (- code 30)))
             ((and (>= code 40) (<= code 47))
              (set-face-bg! attrs (- code 40)))
             ((and (>= code 90) (<= code 97))
              (set-face-fg! attrs (+ 8 (- code 90))))
             ((and (>= code 100) (<= code 107))
              (set-face-bg! attrs (+ 8 (- code 100))))
             ((eq? code 38) (consume-extended-color! attrs 'fg next))
             ((eq? code 48) (consume-extended-color! attrs 'bg next))
             ((eq? code 58) (consume-extended-color! attrs 'ul next))
             (else #f)))
          (loop)))))))

(define (handle-sub-param! sub attrs)
  "Interpret a colon-separated SGR sub-parameter list SUB and apply it
to ATTRS.  Handles underline style (4:n), and extended colour for fg
(38:5:n / 38:2:r:g:b), bg (48:...), and underline (58:...)."
  (case (car sub)
    ((4)
     (set-face-underline!
      attrs
      (case (and (pair? (cdr sub)) (cadr sub))
        ((0)  #f)
        ((1)  'single)
        ((2)  'double)
        ((3)  'curly)
        ((4)  'dotted)
        ((5)  'dashed)
        (else 'single))))
    ((38) (consume-sub-color! attrs sub 'fg))
    ((48) (consume-sub-color! attrs sub 'bg))
    ((58) (consume-sub-color! attrs sub 'ul))))

(define (consume-sub-color! attrs sub slot)
  "Apply colon-form extended colour SUB ('(KIND ...) where KIND is 5
or 2) to ATTRS' SLOT ('fg / 'bg / 'ul)."
  (let ((mode (and (pair? (cdr sub)) (cadr sub))))
    (cond
     ((eq? mode 5)
      (let ((c (and (pair? (cddr sub)) (caddr sub))))
        (when (and c (>= c 0) (<= c 255))
          (case slot
            ((fg) (set-face-fg! attrs c))
            ((bg) (set-face-bg! attrs c))
            ((ul) (set-face-ul-color! attrs c))))))
     ((eq? mode 2)
      (let* ((tail (cddr sub))
             (r (and (pair? tail) (car tail)))
             (g (and r (pair? (cdr tail)) (cadr tail)))
             (b (and g (pair? (cddr tail)) (caddr tail))))
        (when (and r g b
                   (>= r 0) (<= r 255)
                   (>= g 0) (<= g 255)
                   (>= b 0) (<= b 255))
          (let ((rgb (list r g b)))
            (case slot
              ((fg) (set-face-fg! attrs rgb))
              ((bg) (set-face-bg! attrs rgb))
              ((ul) (set-face-ul-color! attrs rgb))))))))))

(define (consume-extended-color! attrs slot next)
  "Read an extended-colour spec from the SGR param iterator NEXT
(a thunk returning the next param) and apply it to SLOT ('fg, 'bg,
or 'ul) of ATTRS.  MODE 5 reads a 0-255 palette index; MODE 2 reads
three 0-255 RGB params.  Drops invalid specs silently."
  (let ((mode (next)))
    (cond
     ((eq? mode 5)
      (let ((c (next)))
        (when (and c (>= c 0) (<= c 255))
          (case slot
            ((fg) (set-face-fg! attrs c))
            ((bg) (set-face-bg! attrs c))
            ((ul) (set-face-ul-color! attrs c))))))
     ((eq? mode 2)
      (let ((r (next)) (g (next)) (b (next)))
        (when (and r g b
                   (>= r 0) (<= r 255)
                   (>= g 0) (<= g 255)
                   (>= b 0) (<= b 255))
          (let ((rgb (list r g b)))
            (case slot
              ((fg) (set-face-fg! attrs rgb))
              ((bg) (set-face-bg! attrs rgb))
              ((ul) (set-face-ul-color! attrs rgb))))))))))
