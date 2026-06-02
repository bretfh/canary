(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (srfi srfi-1)
             ((canary term types)  #:prefix t:)
             ((canary term modes)  #:prefix t:))

(define (fresh)
  (t:make-term #:width 10 #:height 3))

(test-begin "term-modes")

(test-group "the mode table covers the 38 advertised modes"
  (test-assert "*modes* covers at least 38 entries"
               (>= (length t:*modes*) 38))
  (test-assert "ansi modes are tagged 'ansi"
               (every (lambda (def)
                        (memq (t:mode-def-kind def) '(ansi dec-private)))
                      t:*modes*)))

(test-group "mode-def-by-name resolves to the right entry"
  (let ((def (t:mode-def-by-name 'autowrap)))
    (test-assert "autowrap is defined" def)
    (test-equal "autowrap has number 7" 7 (t:mode-def-number def))
    (test-eq "autowrap is DEC-private" 'dec-private (t:mode-def-kind def))
    (test-assert "autowrap defaults to #t" (t:mode-def-default def))))

(test-group "mode-def-by-key matches the parser's (kind . number) lookup"
  (test-eq "DEC ?25 is cursor-visible"
           'cursor-visible
           (t:mode-def-name (t:mode-def-by-key 'dec-private 25)))
  (test-eq "ANSI 4 is insert"
           'insert
           (t:mode-def-name (t:mode-def-by-key 'ansi 4))))

(test-group "a fresh term carries the documented defaults"
  (let ((t (fresh)))
    (test-assert "autowrap on by default"
                 (t:mode-get (t:term-modes t) 'autowrap))
    (test-assert "cursor-visible on by default"
                 (t:mode-get (t:term-modes t) 'cursor-visible))
    (test-assert "insert off by default"
                 (not (t:mode-get (t:term-modes t) 'insert)))
    (test-assert "bracketed-paste off by default"
                 (not (t:mode-get (t:term-modes t) 'bracketed-paste)))
    (test-assert "mouse-sgr off by default"
                 (not (t:mode-get (t:term-modes t) 'mouse-sgr)))
    (test-assert "sync-output off by default"
                 (not (t:mode-get (t:term-modes t) 'sync-output)))))

(test-group "mode-set! flips a flag"
  (let* ((t (fresh))
         (m (t:term-modes t)))
    (t:mode-set! m 'sync-output #t)
    (test-assert "sync-output is now set"
                 (t:mode-get m 'sync-output))
    (t:mode-set! m 'sync-output #f)
    (test-assert "sync-output is cleared"
                 (not (t:mode-get m 'sync-output)))))

(test-group "mode-set! on unknown name is silently ignored"
  (let* ((t (fresh))
         (m (t:term-modes t)))
    (t:mode-set! m 'no-such-mode #t)
    (test-assert "unknown mode reads back #f"
                 (not (t:mode-get m 'no-such-mode)))))

(test-group "save/restore brackets the values"
  (let* ((t (fresh))
         (m (t:term-modes t)))
    (t:mode-set! m 'bracketed-paste #t)
    (t:mode-set! m 'mouse-sgr #t)
    (t:mode-save! m)
    (t:mode-set! m 'bracketed-paste #f)
    (t:mode-set! m 'mouse-sgr #f)
    (test-assert "bracketed-paste cleared after intervening set"
                 (not (t:mode-get m 'bracketed-paste)))
    (t:mode-restore! m)
    (test-assert "bracketed-paste restored"
                 (t:mode-get m 'bracketed-paste))
    (test-assert "mouse-sgr restored"
                 (t:mode-get m 'mouse-sgr))))

(test-group "reset returns every mode to its declared default"
  (let* ((t (fresh))
         (m (t:term-modes t)))
    (t:mode-set! m 'autowrap #f)
    (t:mode-set! m 'cursor-visible #f)
    (t:mode-set! m 'bracketed-paste #t)
    (t:mode-reset! m)
    (test-assert "autowrap back to #t" (t:mode-get m 'autowrap))
    (test-assert "cursor-visible back to #t" (t:mode-get m 'cursor-visible))
    (test-assert "bracketed-paste back to #f"
                 (not (t:mode-get m 'bracketed-paste)))))

(test-end "term-modes")
