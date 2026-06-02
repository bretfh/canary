(define-module (canary term selection)
  #:use-module (srfi srfi-9)
  #:use-module (rnrs bytevectors)
  #:use-module (canary term types)
  #:export (<selection>
            selection?
            selection-start-x
            selection-start-y
            selection-end-x
            selection-end-y
            selection-mode

            term-selection
            set-term-selection!
            term-selection-start!
            term-selection-extend!
            term-selection-clear!
            term-selection-text
            term-cell-selected?))

;;; Commentary:
;;;
;;; A linear cell-range selection model on top of <term>.  Apps set
;;; the selection by responding to mouse drag or key events, then
;;; read term-selection-text for the contiguous selected text (with
;;; wide-character continuation cells and trailing whitespace
;;; handled correctly).  term-cell-selected? answers per-cell, used
;;; by the renderer to overlay an inverse face.
;;;
;;; A <term> holds at most one <selection> at a time, stored in the
;;; (already existing) saved-attrs slot's neighbour space via a
;;; weak hash table here -- adding a slot to <term> would force every
;;; existing call site to migrate, which is more churn than this
;;; feature is worth right now.
;;;
;;; Code:

(define-record-type <selection>
  (%make-selection start-x start-y end-x end-y mode)
  selection?
  (start-x  selection-start-x  set-selection-start-x!)
  (start-y  selection-start-y  set-selection-start-y!)
  (end-x    selection-end-x    set-selection-end-x!)
  (end-y    selection-end-y    set-selection-end-y!)
  (mode     selection-mode     set-selection-mode!))

(define %selections (make-weak-key-hash-table))

(define (term-selection term)
  "Return the <selection> currently attached to TERM, or #f if none."
  (hash-ref %selections term))

(define (set-term-selection! term sel)
  "Attach <selection> SEL (or #f to clear) to TERM."
  (cond
   ((not sel) (hash-remove! %selections term))
   (else      (hash-set! %selections term sel))))

(define* (term-selection-start! term x y #:optional (mode 'char))
  "Begin a selection on TERM anchored at cell (X, Y).  MODE is 'char
(default, contiguous-byte selection), 'word, 'line, or 'block."
  (set-term-selection! term (%make-selection x y x y mode)))

(define (term-selection-extend! term x y)
  "Extend TERM's selection to cell (X, Y) without changing its
anchor.  No-op when there is no active selection."
  (let ((sel (term-selection term)))
    (when sel
      (set-selection-end-x! sel x)
      (set-selection-end-y! sel y))))

(define (term-selection-clear! term)
  "Drop TERM's selection."
  (set-term-selection! term #f))

(define (normalised-range sel)
  "Return (values START-X START-Y END-X END-Y) for SEL with the
anchor and head reordered so START precedes END in reading order."
  (let ((sx (selection-start-x sel)) (sy (selection-start-y sel))
        (ex (selection-end-x sel))   (ey (selection-end-y sel)))
    (cond
     ((or (< sy ey)
          (and (= sy ey) (<= sx ex)))
      (values sx sy ex ey))
     (else
      (values ex ey sx sy)))))

(define (cell-in-range? x y sx sy ex ey w mode)
  "Return #t if cell (X, Y) is inside the linear range (SX,SY)-(EX,EY)
on a W-column grid.  MODE 'block selects the rectangle; everything
else selects the reading-order ribbon."
  (cond
   ((eq? mode 'block)
    (let ((x0 (min sx ex)) (x1 (max sx ex)))
      (and (>= y sy) (<= y ey) (>= x x0) (<= x x1))))
   ((= sy ey) (and (= y sy) (>= x sx) (<= x ex)))
   ((= y sy)  (>= x sx))
   ((= y ey)  (<= x ex))
   (else      (and (> y sy) (< y ey)))))

(define (term-cell-selected? term x y)
  "Return #t if cell (X, Y) is inside TERM's current selection."
  (let ((sel (term-selection term)))
    (cond
     ((not sel) #f)
     (else
      (call-with-values
       (lambda () (normalised-range sel))
       (lambda (sx sy ex ey)
         (cell-in-range? x y sx sy ex ey
                         (term-width term)
                         (selection-mode sel))))))))

(define (term-selection-text term)
  "Return the visible text inside TERM's current selection as a
single string.  Sentinel (wide-char continuation) cells are skipped;
trailing whitespace is trimmed per row; rows are joined with newline."
  (let ((sel (term-selection term)))
    (cond
     ((not sel) "")
     (else
      (call-with-values
       (lambda () (normalised-range sel))
       (lambda (sx sy ex ey)
         (let ((w (term-width term))
               (h (term-height term))
               (mode (selection-mode sel))
               (out (open-output-string)))
           (do ((y sy (+ y 1)))
               ((or (> y ey) (>= y h)))
             (unless (= y sy) (display "\n" out))
             (let* ((x0 (cond
                         ((eq? mode 'block) (min sx ex))
                         ((= y sy) sx)
                         (else 0)))
                    (x1 (cond
                         ((eq? mode 'block) (max sx ex))
                         ((= y ey) ex)
                         (else (- w 1))))
                    (row-out (open-output-string)))
               (do ((x x0 (+ x 1)))
                   ((> x x1))
                 (when (< x w)
                   (let ((ch (term-char-at term x y)))
                     (unless (zero? (char->integer ch))
                       (display ch row-out)))))
               (let ((row (get-output-string row-out)))
                 (display (string-trim-right-spaces row) out))))
           (get-output-string out))))))))

(define (string-trim-right-spaces s)
  "Return S without any trailing space characters."
  (let loop ((i (string-length s)))
    (cond
     ((zero? i) "")
     ((char=? (string-ref s (- i 1)) #\space) (loop (- i 1)))
     (else (substring s 0 i)))))
