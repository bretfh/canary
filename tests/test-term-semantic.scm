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

(define (semantic-at term x y)
  (let ((f (t:term-face-at term x y)))
    (and f (t:face-semantic f))))

(test-begin "term-semantic")

(test-group "OSC 133 ; A tags cells as 'prompt"
  (let ((t (t:make-term #:width 10 #:height 1)))
    (t:term-process-output! t "\x1b]133;A\x1b\\$ ")
    (test-eq "cell 0 is 'prompt" 'prompt (semantic-at t 0 0))
    (test-eq "cell 1 is 'prompt" 'prompt (semantic-at t 1 0))))

(test-group "OSC 133 ; B/C/D transitions update the active tag"
  (let ((t (t:make-term #:width 30 #:height 1)))
    (t:term-process-output! t
      (string-append
       "\x1b]133;A\x1b\\>\x1b]133;B\x1b\\cd\x1b]133;C\x1b\\out\x1b]133;D\x1b\\after"))
    (test-eq "the '>' cell is 'prompt" 'prompt (semantic-at t 0 0))
    (test-eq "the 'c' cell is 'input"  'input  (semantic-at t 1 0))
    (test-eq "the 'd' cell is 'input"  'input  (semantic-at t 2 0))
    (test-eq "the 'o' cell is 'output" 'output (semantic-at t 3 0))
    (test-assert "post-D cells carry no tag"
                 (not (semantic-at t 6 0)))))

(test-group "diff-to-ansi emits OSC 133 markers around tagged runs"
  (let ((t (t:make-term #:width 10 #:height 1)))
    (t:term-process-output! t "\x1b]133;A\x1b\\$ \x1b]133;C\x1b\\x")
    (let ((diff (t:term-diff->ansi #f t)))
      (test-assert "diff contains an 'A' marker"
                   (string-contains diff "\x1b]133;A\x1b\\"))
      (test-assert "diff contains a 'C' marker"
                   (string-contains diff "\x1b]133;C\x1b\\")))))

(test-group "(prompt-zone body) round-trips through render and parser"
  (let* ((node (prompt-zone (txt "$ ")))
         (rect (make-rect 0 0 10 1))
         (cmds (view->cmds node rect -1 -1))
         (text (find text-cmd? cmds)))
    (test-assert "a text cmd was produced" text)
    (test-eq "the face carries the 'prompt tag"
             'prompt (face-semantic (text-face text))))
  (let* ((node (prompt-zone (txt "$ ")))
         (term (t:make-term #:width 10 #:height 1))
         (cmds (view->cmds node (make-rect 0 0 10 1) -1 -1)))
    (render-cmds-to-term! term cmds default-faces)
    (test-eq "cell 0 carries 'prompt"
             'prompt (semantic-at term 0 0))
    (let* ((ansi (t:term-diff->ansi #f term))
           (t2   (t:make-term #:width 10 #:height 1)))
      (t:term-process-output! t2 ansi)
      (test-eq "round-trip preserves 'prompt"
               'prompt (semantic-at t2 0 0)))))

(test-end "term-semantic")
