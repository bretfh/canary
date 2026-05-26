(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (srfi srfi-13)
             (canary layout)
             (canary term types)
             (canary term render)
             (canary term snapshot))

(define (trim-trailing-spaces-per-line s)
  (string-join (map (lambda (line) (string-trim-right line #\space))
                    (string-split s #\newline))
               "\n"))

(test-begin "term-snapshot")

(test-group "view->grid renders a tree into a fresh <term>"
  (let ((t (view->grid (vbox (txt "hello") (txt "world"))
                       #:cols 10 #:rows 3)))
    (test-equal "snapshot trimmed per-line"
                "hello\nworld\n"
                (trim-trailing-spaces-per-line (term->text-snapshot t)))))

(test-group "snapshot-equal? compares byte-exactly"
  (let* ((a (term->text-snapshot (view->grid (txt "a") #:cols 5 #:rows 1)))
         (b (term->text-snapshot (view->grid (txt "a") #:cols 5 #:rows 1)))
         (c (term->text-snapshot (view->grid (txt "b") #:cols 5 #:rows 1))))
    (test-assert "same render -> equal snapshot" (snapshot-equal? a b))
    (test-assert "different render -> not equal"
                 (not (snapshot-equal? a c)))))

(test-group "call-with-fresh-term hands a clean grid to a procedure"
  (let ((dims (call-with-fresh-term
               (lambda (t) (cons (term-width t) (term-height t)))
               #:cols 20 #:rows 5)))
    (test-equal "got the requested cols" 20 (car dims))
    (test-equal "got the requested rows"  5 (cdr dims))))

(test-group "replay-ansi parses a recorded byte stream into a term"
  (let ((t (replay-ansi "abc\x1b[2;1Hxyz" #:cols 10 #:rows 3)))
    (test-equal "row 0 first chars"
                "abc"
                (string-trim-right (term-dump-row t 0) #\space))
    (test-equal "row 1 first chars"
                "xyz"
                (string-trim-right (term-dump-row t 1) #\space))))

(test-group "term->ansi-snapshot can re-parse through replay-ansi"
  (let* ((t1 (view->grid (txt "hi") #:cols 5 #:rows 1))
         (ansi (term->ansi-snapshot t1))
         (t2 (replay-ansi ansi #:cols 5 #:rows 1)))
    (test-equal "re-parsed grid matches the dumped text"
                (term->text-snapshot t1)
                (term->text-snapshot t2))))

(test-end "term-snapshot")
