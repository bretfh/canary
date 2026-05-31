(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (srfi srfi-13)
             ((gcell term types) #:prefix t:)
             ((gcell term ops)   #:prefix t:)
             ((gcell term write) #:prefix t:)
             ((gcell term render) #:prefix t:))

(define (fresh w h)
  (t:make-term #:width w #:height h))

(define (row-of t y)
  (string-trim-right (t:term-dump-row t y) #\space))

(test-begin "term-pending-wrap")

(test-group "writing at the last column sets pending-wrap, cursor stays"
  (let ((t (fresh 5 3)))
    (t:term-write! t "abcde")
    (test-equal "cursor x at last column"   4 (t:term-cursor-x t))
    (test-equal "cursor y unchanged"        0 (t:term-cursor-y t))
    (test-assert "pending-wrap is set"      (t:term-pending-wrap? t))
    (test-equal "row 0 has 'abcde'"
                "abcde" (row-of t 0))))

(test-group "next print consumes pending-wrap and wraps under DECAWM"
  (let ((t (fresh 5 3)))
    (t:term-write! t "abcde")
    (t:term-write! t "f")
    (test-equal "cursor x after wrap+write" 1 (t:term-cursor-x t))
    (test-equal "cursor y after wrap"       1 (t:term-cursor-y t))
    (test-assert "pending-wrap cleared"     (not (t:term-pending-wrap? t)))
    (test-equal "row 0 unchanged"
                "abcde" (row-of t 0))
    (test-equal "row 1 starts with 'f'"
                "f" (row-of t 1))))

(test-group "with autowrap off, the next print overwrites the last cell"
  (let ((t (fresh 5 3)))
    (t:mode-set! (t:term-modes t) 'autowrap #f)
    (t:term-write! t "abcde")
    (t:term-write! t "Z")
    (test-equal "cursor x stays at last column" 4 (t:term-cursor-x t))
    (test-equal "cursor y stays"                0 (t:term-cursor-y t))
    (test-equal "last cell overwritten with Z"
                "abcdZ" (row-of t 0))
    (test-equal "row 1 still blank"
                "" (row-of t 1))))

(test-group "carriage return clears pending-wrap"
  (let ((t (fresh 5 3)))
    (t:term-write! t "abcde")
    (t:term-carriage-return! t)
    (test-assert "pending-wrap cleared by CR"
                 (not (t:term-pending-wrap? t)))
    (test-equal "cursor returned to col 0"
                0 (t:term-cursor-x t))))

(test-group "line feed clears pending-wrap"
  (let ((t (fresh 5 3)))
    (t:term-write! t "abcde")
    (t:term-line-feed! t)
    (test-assert "pending-wrap cleared by LF"
                 (not (t:term-pending-wrap? t)))
    (test-equal "cursor advanced to next row"
                1 (t:term-cursor-y t))))

(test-group "explicit cursor moves clear pending-wrap"
  (let ((t (fresh 5 3)))
    (t:term-write! t "abcde")
    (t:term-cursor-left! t 1)
    (test-assert "pending-wrap cleared by cursor-left"
                 (not (t:term-pending-wrap? t))))
  (let ((t (fresh 5 3)))
    (t:term-write! t "abcde")
    (t:term-goto! t 2 1)
    (test-assert "pending-wrap cleared by goto"
                 (not (t:term-pending-wrap? t)))))

(test-group "save and restore preserve pending-wrap"
  (let ((t (fresh 5 3)))
    (t:term-write! t "abcde")
    (t:term-save-cursor! t)
    (test-assert "saved-pending-wrap captures the set flag"
                 (t:term-saved-pending-wrap? t))
    (t:term-goto! t 2 3)
    (test-assert "pending-wrap is now cleared"
                 (not (t:term-pending-wrap? t)))
    (t:term-restore-cursor! t)
    (test-assert "restore brings pending-wrap back"
                 (t:term-pending-wrap? t))
    (test-equal "cursor x restored to last column"
                4 (t:term-cursor-x t))
    (test-equal "cursor y restored"
                0 (t:term-cursor-y t))))

(test-group "wrap at the scroll bottom scrolls the region"
  (let ((t (fresh 5 2)))
    (t:term-write! t "abcde")
    (t:term-line-feed! t)
    (t:term-write! t "fghij")
    (test-assert "pending-wrap set at the bottom"
                 (t:term-pending-wrap? t))
    (t:term-write! t "k")
    (test-equal "row 0 has scrolled up to be 'fghij'"
                "fghij" (row-of t 0))
    (test-equal "row 1 starts with 'k' after wrap+scroll"
                "k" (row-of t 1))
    (test-equal "cursor on the bottom row, col 1"
                1 (t:term-cursor-x t))
    (test-equal "cursor on the bottom row"
                1 (t:term-cursor-y t))))

(test-group "wide char that doesn't fit at last column wraps without LCF"
  (let ((t (fresh 5 3)))
    (t:term-write! t "abcd")
    (test-equal "cursor pre-wide at col 4" 4 (t:term-cursor-x t))
    (test-assert "no pending-wrap before"  (not (t:term-pending-wrap? t)))
    (t:term-write! t "字")
    (test-equal "cursor on row 1 after wrap" 1 (t:term-cursor-y t))
    (test-equal "cursor advanced past wide char" 2 (t:term-cursor-x t))
    (test-equal "row 1 starts with the wide char"
                "字" (row-of t 1))))

(test-end "term-pending-wrap")
