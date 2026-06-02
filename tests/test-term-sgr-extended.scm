(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (srfi srfi-13)
             ((canary term types)  #:prefix t:)
             ((canary term parser) #:prefix t:)
             ((canary term render) #:prefix t:))

(define (face-at term x y)
  (t:term-face-at term x y))

(test-begin "term-sgr-extended")

(test-group "CSI 4:n m maps to underline style symbols"
  (let ((t (t:make-term #:width 10 #:height 1)))
    (t:term-process-output! t "\x1b[4:3mA\x1b[4:5mB\x1b[4:0mC")
    (test-eq "A under curly"    'curly  (t:face-underline (face-at t 0 0)))
    (test-eq "B under dashed"   'dashed (t:face-underline (face-at t 1 0)))
    (test-assert "C has no underline"
                 (not (t:face-underline (face-at t 2 0))))))

(test-group "CSI 58 sets underline colour"
  (let ((t (t:make-term #:width 5 #:height 1)))
    (t:term-process-output! t "\x1b[4;58:5:42mX\x1b[59mY")
    (test-equal "X carries ul-color 42"
                42 (t:face-ul-color (face-at t 0 0)))
    (test-assert "Y reset clears ul-color"
                 (not (t:face-ul-color (face-at t 1 0))))))

(test-group "CSI 53 / 55 toggle the overline flag"
  (let ((t (t:make-term #:width 5 #:height 1)))
    (t:term-process-output! t "\x1b[53mA\x1b[55mB")
    (test-assert "A is overlined"      (t:face-overline? (face-at t 0 0)))
    (test-assert "B is not overlined"
                 (not (t:face-overline? (face-at t 1 0))))))

(test-group "diff-to-ansi emits the new SGR codes"
  (let ((t (t:make-term #:width 5 #:height 1)))
    (t:term-process-output! t "\x1b[4:3;53mx")
    (let ((diff (t:term-diff->ansi #f t)))
      (test-assert "diff carries 4:3 for curly underline"
                   (string-contains diff "4:3"))
      (test-assert "diff carries 53 for overline"
                   (string-contains diff "53")))))

(test-end "term-sgr-extended")
