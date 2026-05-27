(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (canary key)
             (canary keymap)
             (canary keymap-input)
             (canary view)
             (canary layout)
             (canary render)
             (canary draw))

(test-begin "keymap-stack")

(define %inner (keymap (bind #\a 'inner-a)
                       (bind #\b 'inner-b)))

(define %outer (keymap (bind #\b 'outer-b)
                       (bind #\c 'outer-c)))

(define %global (keymap (bind #\d 'global-d)
                        (bind '(#\x ctrl) '(#\c ctrl) 'global-chord)))

(define stack (list %inner %outer %global))

(test-equal "innermost wins when both bind the same key"
            'inner-b
            (call-with-values (lambda () (feed-key-stack stack (key #\b)))
              (lambda (a _) a)))

(test-equal "no-shadow falls through to outer"
            'outer-c
            (call-with-values (lambda () (feed-key-stack stack (key #\c)))
              (lambda (a _) a)))

(test-equal "falls through to global"
            'global-d
            (call-with-values (lambda () (feed-key-stack stack (key #\d)))
              (lambda (a _) a)))

(test-equal "unbound returns #f"
            #f
            (call-with-values (lambda () (feed-key-stack stack (key #\z)))
              (lambda (a _) a)))

(test-equal "innermost-only match still wins"
            'inner-a
            (call-with-values (lambda () (feed-key-stack stack (key #\a)))
              (lambda (a _) a)))

(test-equal "empty stack returns #f"
            #f
            (call-with-values (lambda () (feed-key-stack '() (key #\a)))
              (lambda (a _) a)))

(test-equal "single-keymap stack returns its action"
            'inner-a
            (call-with-values (lambda () (feed-key-stack (list %inner) (key #\a)))
              (lambda (a _) a)))

;; Chord state on the global keymap survives the stack walk: the
;; returned list preserves the updated keymap.
(test-equal "pending chord on global keymap reports pending"
            'pending
            (call-with-values
                (lambda () (feed-key-stack stack (key #\x 'control)))
              (lambda (a _) a)))

(test-equal "pending chord completes via the returned global"
            'global-chord
            (call-with-values
                (lambda () (feed-key-stack stack (key #\x 'control)))
              (lambda (_ new-stack)
                (call-with-values
                    (lambda () (feed-key-stack new-stack (key #\c 'control)))
                  (lambda (a _) a)))))

;; `with-keymap` is a transparent decorator at render time: the body
;; renders verbatim, no extra cmds are emitted, and size matches the
;; body's intrinsic size.
(define (text-of cmds)
  (let ((tc (find text-cmd? cmds)))
    (and tc (text-str tc))))

(let* ((wrapped (with-keymap %inner (txt "hi"))))
  (test-equal "with-keymap is transparent — body text renders"
              "hi"
              (text-of (render wrapped 10 1))))

(let* ((bare    (txt "hi"))
       (wrapped (with-keymap %inner (txt "hi"))))
  (test-equal "with-keymap preserves intrinsic size"
              (view-size bare)
              (view-size wrapped)))

(let* ((tree  (on-click (with-keymap %inner (txt "btn")) #:action 'fire))
       (cmds  (render tree 10 1))
       (click (find clickable-cmd? cmds)))
  (test-assert "click region passes through with-keymap"
               (and click (eq? (clickable-action click) 'fire))))

(test-end "keymap-stack")
