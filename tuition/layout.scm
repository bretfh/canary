;;; layout.scm --- Layout primitives for TUI

(define-module (tuition layout)
  #:use-module (tuition style)
  #:use-module (tuition text)
  #:use-module (tuition app)
  #:use-module (srfi srfi-1)
  #:export (txt
            vbox
            hbox
            spacer
            join
            error-console
            pad
            align
            width
            height))

(define* (txt str #:key bold? italic? underline? strikethrough? (fg #f) (bg #f))
  "Create styled text"
  (let ((result str))
    (when bold? (set! result (bold result)))
    (when italic? (set! result (italic result)))
    (when underline? (set! result (underline result)))
    (when strikethrough? (set! result (strikethrough result)))
    (when fg (set! result ((@ (tuition style) fg) result fg)))
    (when bg (set! result ((@ (tuition style) bg) result bg)))
    result))

(define (vbox . elements)
  "Stack elements vertically"
  (string-join (filter (lambda (e) (and e (not (string=? e ""))))
                       elements)
               nl))

(define (strip-cr str)
  (if (and (> (string-length str) 0)
           (char=? (string-ref str (- (string-length str) 1)) #\return))
      (substring str 0 (- (string-length str) 1))
      str))

(define (hbox . elements)
  (let* ((filtered (filter (lambda (e) (and e (not (string=? e "")))) elements))
         (split-elements (map (lambda (e)
                               (map strip-cr (string-split e #\newline)))
                             filtered)))
    (if (null? split-elements)
        ""
        (let ((max-height (apply max (map length split-elements))))
          (let ((padded (map (lambda (lines)
                              (let* ((max-w (if (null? lines) 0 (apply max (map visible-length lines))))
                                     (padded-lines (map (lambda (line)
                                                         (let ((pad (- max-w (visible-length line))))
                                                           (string-append line (make-string pad #\space))))
                                                       lines))
                                     (missing (- max-height (length padded-lines))))
                                (append padded-lines (make-list missing (make-string max-w #\space)))))
                            split-elements)))
            (string-join
             (map (lambda (row-idx)
                   (string-join
                    (map (lambda (elem-lines)
                          (list-ref elem-lines row-idx))
                         padded)
                    ""))
                  (iota max-height))
             nl))))))

(define (spacer n)
  "Create n blank lines"
  (string-join (make-list n "") nl))

(define (join . elements)
  "Join elements with newlines (alias for vbox)"
  (apply vbox elements))

(define* (error-console app-instance #:key (max-lines 5))
  (let ((errs (get-errors app-instance)))
    (if (null? errs)
        ""
        (vbox
         (txt "─── Errors ───" #:fg "#ff0000" #:bold? #t)
         (apply vbox
                (map (lambda (e) (txt (format #f "  ~a" e) #:fg "#ff0000"))
                     (take errs (min max-lines (length errs)))))))))

(define (truncate-line line max-width)
  (let loop ((i 0) (visible-count 0))
    (if (or (>= i (string-length line)) (>= visible-count max-width))
        (substring line 0 i)
        (let ((ch (string-ref line i)))
          (if (char=? ch #\escape)
              (let ((next-i (+ i 1)))
                (if (and (< next-i (string-length line))
                        (char=? (string-ref line next-i) #\[))
                    (let skip-csi ((k (+ next-i 1)))
                      (if (>= k (string-length line))
                          (loop k visible-count)
                          (let ((code (char->integer (string-ref line k))))
                            (if (and (>= code #x40) (<= code #x7E))
                                (loop (+ k 1) visible-count)
                                (skip-csi (+ k 1))))))
                    (loop next-i visible-count)))
              (loop (+ i 1) (+ visible-count 1)))))))

(define (pad-line line target-width mode)
  (let* ((vlen (visible-length line))
         (padding (- target-width vlen)))
    (cond
     ((<= padding 0) line)
     ((eq? mode 'center)
      (let* ((left (quotient padding 2))
             (right (- padding left)))
        (string-append (make-string left #\space) line (make-string right #\space))))
     ((eq? mode 'right)
      (string-append (make-string padding #\space) line))
     (else
      (string-append line (make-string padding #\space))))))

(define* (pad content #:key (top 0) (bottom 0) (left 0) (right 0) (all 0))
  (let* ((t (if (> all 0) all top))
         (b (if (> all 0) all bottom))
         (l (if (> all 0) all left))
         (r (if (> all 0) all right))
         (lines (map strip-cr (string-split content #\newline)))
         (max-w (if (null? lines) 0 (apply max (map visible-length lines))))
         (total-w (+ l max-w r))
         (padded (map (lambda (line)
                       (string-append (make-string l #\space)
                                     line
                                     (make-string (- total-w l (visible-length line)) #\space)))
                     lines))
         (blank (make-string total-w #\space)))
    (string-join (append (make-list t blank) padded (make-list b blank)) nl)))

(define* (align content mode #:key (width-val #f))
  (let* ((lines (map strip-cr (string-split content #\newline)))
         (target-w (or width-val (if (null? lines) 0 (apply max (map visible-length lines))))))
    (string-join (map (lambda (line) (pad-line line target-w mode)) lines) nl)))

(define* (width content w #:key (align-mode 'left))
  (let ((lines (map strip-cr (string-split content #\newline))))
    (string-join
     (map (lambda (line)
           (let ((vlen (visible-length line)))
             (cond
              ((> vlen w) (truncate-line line w))
              ((< vlen w) (pad-line line w align-mode))
              (else line))))
          lines)
     nl)))

(define* (height content h #:key (valign 'top))
  (let* ((lines (map strip-cr (string-split content #\newline)))
         (current-h (length lines))
         (max-w (if (null? lines) 0 (apply max (map visible-length lines))))
         (blank (make-string max-w #\space)))
    (cond
     ((> current-h h) (string-join (take lines h) nl))
     ((< current-h h)
      (let* ((padding (- h current-h))
             (top-pad (if (eq? valign 'center) (quotient padding 2)
                         (if (eq? valign 'bottom) padding 0)))
             (bottom-pad (- padding top-pad)))
        (string-join (append (make-list top-pad blank) lines (make-list bottom-pad blank)) nl)))
     (else content))))
