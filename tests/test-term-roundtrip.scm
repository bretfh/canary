(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (srfi srfi-1)
             (canary view)
             (canary layout)
             (canary borders)
             (canary faces)
             (canary theme)
             (canary draw)
             (canary render)
             (canary backend-ansi)
             ((canary term types) #:prefix t:)
             ((canary term parser) #:prefix t:)
             ((canary term render) #:prefix t:))

(define (render-to-grid node w h)
  (let ((cmds (render node w h))
        (term (t:make-term #:width w #:height h)))
    (render-cmds-to-term! term cmds default-faces)
    term))

(define (row-of term y)
  (string-trim-right (t:term-dump-row term y) #\space))

(define (replay-ansi-into-fresh-term ansi w h)
  (let ((term (t:make-term #:width w #:height h)))
    (t:term-process-output! term ansi)
    term))

(test-begin "term-roundtrip")

(test-group "text renders into the grid"
  (let ((term (render-to-grid (txt "hello") 20 3)))
    (test-equal "row 0 has the text" "hello" (row-of term 0))
    (test-equal "row 1 is blank" "" (row-of term 1))))

(test-group "vbox places lines on consecutive rows"
  (let ((term (render-to-grid (vbox (txt "abc") (txt "def")) 10 3)))
    (test-equal "row 0" "abc" (row-of term 0))
    (test-equal "row 1" "def" (row-of term 1))
    (test-equal "row 2" "" (row-of term 2))))

(test-group "hbox places spans on the same row"
  (let ((term (render-to-grid (hbox (txt "ab") (txt "cd")) 10 1)))
    (test-equal "row 0 joined" "abcd" (row-of term 0))))

(test-group "boxed border lands at the right cells"
  (let ((term (render-to-grid (boxed (txt "x")) 5 3)))
    (test-equal "top    " "┌───┐" (row-of term 0))
    (test-equal "middle " "│x  │" (row-of term 1))
    (test-equal "bottom " "└───┘" (row-of term 2))))

(test-group "cmds->ansi is replay-equivalent"
  (let* ((node (vbox (txt "alpha") (txt "beta") (boxed (txt "γ"))))
         (cmds (render node 12 6))
         (direct (render-to-grid node 12 6))
         (via-ansi (replay-ansi-into-fresh-term (cmds->ansi cmds default-faces) 12 6)))
    (test-equal "dump matches direct render" (t:term-dump direct) (t:term-dump via-ansi))))

(test-group "diff emits only changed cells"
  (let* ((w 8) (h 2)
         (t1 (render-to-grid (vbox (txt "aaa") (txt "bbb")) w h))
         (t2 (render-to-grid (vbox (txt "aXa") (txt "bbb")) w h))
         (diff (t:term-diff->ansi t1 t2))
         (replayed (let ((term (t:make-term #:width w #:height h)))
                     (t:term-process-output! term (t:term-render-ansi-line t1 0))
                     (t:term-process-output! term "\x1b[2;1H")
                     (t:term-process-output! term (t:term-render-ansi-line t1 1))
                     (t:term-process-output! term "\x1b[H")
                     (t:term-process-output! term diff)
                     term)))
    (test-equal "diff applied on top of t1 yields t2"
                (t:term-dump t2) (t:term-dump replayed))
    (test-assert "diff is shorter than full repaint"
                 (< (string-length diff)
                    (string-length (cmds->ansi (render
                                                 (vbox (txt "aXa") (txt "bbb"))
                                                 w h)
                                               default-faces))))))

(test-group "face round-trips through the grid"
  (let* ((red-face (face #:fg "#ff0000" #:attrs '(bold)))
         (cmds-with-face (list ((@@ (canary draw) make-text) 0 0 "go" red-face '())))
         (term (t:make-term #:width 4 #:height 1)))
    (render-cmds-to-term! term cmds-with-face default-theme)
    (test-equal "char is 'g'" #\g (t:term-char-at term 0 0))
    (let ((face (t:term-face-at term 0 0)))
      (test-assert "face exists" face)
      (test-equal "fg is RGB list" '(255 0 0) (t:face-fg face))
      (test-assert "bold is set" (t:face-bold? face)))))

(test-group "diff is empty when nothing changes"
  (let ((node (vbox (txt "stable") (txt "rows"))))
    (let* ((t1 (render-to-grid node 10 3))
           (t2 (render-to-grid node 10 3))
           (diff (t:term-diff->ansi t1 t2)))
      (test-assert "diff contains no cell writes"
                   (not (string-contains diff "stable")))
      (test-assert "diff contains no cell writes for second line"
                   (not (string-contains diff "rows"))))))

(test-group "shrinking the terminal does not leave stale cells"
  (let* ((big (render-to-grid (txt "0123456789") 12 2))
         (small (render-to-grid (txt "abc") 5 1))
         (diff (t:term-diff->ansi #f small)))
    (test-equal "small grid dumps correctly" "abc  " (t:term-dump-row small 0))
    (test-assert "no leftover digits in the diff (fresh repaint)"
                 (not (string-contains diff "0123456789")))))

(test-end "term-roundtrip")
