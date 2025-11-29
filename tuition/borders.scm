;;; borders.scm --- Border rendering for boxes

(define-module (tuition borders)
  #:use-module (tuition style)
  #:use-module (tuition text)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:export (<border>
            border?
            border-top
            border-bottom
            border-left
            border-right
            border-tl
            border-tr
            border-bl
            border-br
            border-normal
            border-rounded
            border-thick
            border-double
            border-ascii
            make-border
            boxed))

;;; Border style record
(define-record-type <border>
  (make-border top bottom left right tl tr bl br)
  border?
  (top border-top)
  (bottom border-bottom)
  (left border-left)
  (right border-right)
  (tl border-tl)      ; top-left
  (tr border-tr)      ; top-right
  (bl border-bl)      ; bottom-left
  (br border-br))     ; bottom-right

;;; Predefined border styles
(define border-normal
  (make-border "─" "─" "│" "│" "┌" "┐" "└" "┘"))

(define border-rounded
  (make-border "─" "─" "│" "│" "╭" "╮" "╰" "╯"))

(define border-thick
  (make-border "━" "━" "┃" "┃" "┏" "┓" "┗" "┛"))

(define border-double
  (make-border "═" "═" "║" "║" "╔" "╗" "╚" "╝"))

(define border-ascii
  (make-border "-" "-" "|" "|" "+" "+" "+" "+"))

;;; Render text with border
(define (strip-cr str)
  (if (and (> (string-length str) 0)
           (char=? (string-ref str (- (string-length str) 1)) #\return))
      (substring str 0 (- (string-length str) 1))
      str))

(define* (boxed text #:key
                (border border-normal)
                (fg #f)
                (bg #f)
                (bold? #f))
  "Wrap text in a border"
  (let* ((lines (filter (lambda (s) (not (string=? s "")))
                        (map strip-cr (string-split text #\newline))))
         (max-width (apply max (map visible-length lines)))
         (top-line (string-append (border-tl border)
                                 (make-string max-width (string-ref (border-top border) 0))
                                 (border-tr border)))
         (bottom-line (string-append (border-bl border)
                                    (make-string max-width (string-ref (border-bottom border) 0))
                                    (border-br border)))
         (content-lines (map (lambda (line)
                              (let ((padding (- max-width (visible-length line))))
                                (string-append (border-left border)
                                             line
                                             (make-string padding #\space)
                                             (border-right border))))
                            lines))
         (all-lines (cons top-line (append content-lines (list bottom-line))))
         (colored-lines (cond
                         ((and fg bg)
                          (map (lambda (line)
                                ((@ (tuition style) bg)
                                 ((@ (tuition style) fg) line fg) bg))
                               all-lines))
                         (fg
                          (map (lambda (line) ((@ (tuition style) fg) line fg))
                               all-lines))
                         (bg
                          (map (lambda (line) ((@ (tuition style) bg) line bg))
                               all-lines))
                         (bold?
                          (map (lambda (line) ((@ (tuition style) bold) line))
                               all-lines))
                         (else all-lines))))
    (string-join colored-lines nl)))
