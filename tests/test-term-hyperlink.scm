(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (srfi srfi-1)
             (srfi srfi-13)
             (gcell layout)
             (gcell view)
             (gcell draw)
             (gcell faces)
             (gcell render)
             (gcell backend-ansi)
             ((gcell term types)  #:prefix t:)
             ((gcell term parser) #:prefix t:)
             ((gcell term render) #:prefix t:))

(define (make-term . args) (apply t:make-term args))
(define (term-process-output! . args) (apply t:term-process-output! args))
(define (term-face-at . args) (apply t:term-face-at args))
(define (term-diff->ansi . args) (apply t:term-diff->ansi args))

(define example "https://example.com")

(define (hyperlink-at t x y)
  (let ((f (t:term-face-at t x y)))
    (and f (t:face-hyperlink f))))

(test-begin "term-hyperlink")

(test-group "OSC 8 opens a hyperlink that future cells carry"
  (let ((t (t:make-term #:width 20 #:height 1)))
    (t:term-process-output! t
      (string-append "\x1b]8;;" example "\x1b\\hello\x1b]8;;\x1b\\ world"))
    (test-equal "cell 0 carries the uri" example (hyperlink-at t 0 0))
    (test-equal "cell 4 still carries the uri" example (hyperlink-at t 4 0))
    (test-assert "cell 5 has no uri after close"
                 (not (hyperlink-at t 5 0)))
    (test-assert "cell 10 has no uri" (not (hyperlink-at t 10 0)))))

(test-group "BEL-terminated OSC 8 works too"
  (let ((t (t:make-term #:width 10 #:height 1)))
    (t:term-process-output! t
      (string-append "\x1b]8;;" example "\x07x\x1b]8;;\x07"))
    (test-equal "cell 0 has uri" example (hyperlink-at t 0 0))))

(test-group "SGR reset 0m does not clear the hyperlink"
  (let ((t (t:make-term #:width 10 #:height 1)))
    (t:term-process-output! t
      (string-append "\x1b]8;;" example "\x1b\\\x1b[31mA\x1b[0mB\x1b]8;;\x1b\\"))
    (test-equal "A under red+link"   example (hyperlink-at t 0 0))
    (test-equal "B after SGR reset still under link"
                example (hyperlink-at t 1 0))))

(test-group "diff-to-ansi emits OSC 8 around hyperlinked runs"
  (let ((t (t:make-term #:width 10 #:height 1)))
    (t:term-process-output! t
      (string-append "\x1b]8;;" example "\x1b\\hi\x1b]8;;\x1b\\"))
    (let ((diff (t:term-diff->ansi #f t)))
      (test-assert "diff opens the link"
                   (string-contains diff
                     (string-append "\x1b]8;;" example "\x1b\\")))
      (test-assert "diff closes the link"
                   (string-contains diff "\x1b]8;;\x1b\\")))))

(test-group "round-trip: parse, re-emit, parse again yields the same cells"
  (let* ((t1 (t:make-term #:width 10 #:height 1))
         (in (string-append "\x1b]8;;" example "\x1b\\abc\x1b]8;;\x1b\\")))
    (t:term-process-output! t1 in)
    (let* ((out (t:term-diff->ansi #f t1))
           (t2 (t:make-term #:width 10 #:height 1)))
      (t:term-process-output! t2 out)
      (test-equal "t2 cell 0 carries the uri"
                  example (hyperlink-at t2 0 0))
      (test-equal "t2 cell 2 carries the uri"
                  example (hyperlink-at t2 2 0))
      (test-assert "t2 cell 3 has no uri"
                   (not (hyperlink-at t2 3 0))))))

(test-group "(link uri body) renders cells under the uri"
  (let* ((node (link "https://gcell.example" (txt "ok")))
         (rect (make-rect 0 0 10 1))
         (cmds (view->cmds node rect -1 -1))
         (text (find text-cmd? cmds))
         (face (and text (text-face text))))
    (test-assert "a text-cmd was emitted" text)
    (test-assert "its face is a <face> record" (and face (face? face)))
    (test-equal "the face's hyperlink is the uri"
                "https://gcell.example"
                (face-hyperlink face))))

(test-group "(link uri body) round-trips through render and the parser"
  (let* ((node (link "https://gcell.example" (txt "hi")))
         (term (make-term #:width 10 #:height 1))
         (cmds (view->cmds node (make-rect 0 0 10 1) -1 -1)))
    (render-cmds-to-term! term cmds default-faces)
    (test-equal "term cell 0 carries the uri"
                "https://gcell.example"
                (let ((f (term-face-at term 0 0))) (and f (t:face-hyperlink f))))
    (let* ((ansi (term-diff->ansi #f term))
           (t2   (make-term #:width 10 #:height 1)))
      (term-process-output! t2 ansi)
      (test-equal "re-parsed term still has the uri"
                  "https://gcell.example"
                  (let ((f (term-face-at t2 0 0))) (and f (t:face-hyperlink f)))))))

(test-end "term-hyperlink")
