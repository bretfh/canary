(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             ((canary term types)     #:prefix t:)
             ((canary term ops)       #:prefix t:)
             ((canary term write)     #:prefix t:)
             ((canary term parser)    #:prefix t:)
             ((canary term base64)    #:prefix t:)
             ((canary term selection) #:prefix t:))

(test-begin "term-selection")

(test-group "base64 round-trips a clipboard payload"
  (test-equal "encode"
              "aGVsbG8="
              (t:string->base64 "hello"))
  (test-equal "decode"
              "hello"
              (t:base64->string "aGVsbG8="))
  (test-equal "round-trip"
              "one two three"
              (t:base64->string (t:string->base64 "one two three"))))

(test-group "OSC 52 SET fires clipboard-fn with the decoded payload"
  (let ((seen #f))
    (let ((t (t:make-term
              #:width 10 #:height 1
              #:clipboard-fn
              (lambda (term sel action value)
                (set! seen (list sel action value))))))
      (t:term-process-output! t "\x1b]52;c;aGVsbG8=\x1b\\")
      (test-equal "selection was 'c'" "c" (car seen))
      (test-eq "action was 'set" 'set (cadr seen))
      (test-equal "decoded payload" "hello" (caddr seen)))))

(test-group "OSC 52 ? fires clipboard-fn as a query"
  (let ((kind #f))
    (let ((t (t:make-term
              #:width 10 #:height 1
              #:clipboard-fn
              (lambda (term sel action value) (set! kind action)))))
      (t:term-process-output! t "\x1b]52;c;?\x1b\\")
      (test-eq "action was 'get" 'get kind))))

(test-group "selection ranges contain the right cells"
  (let ((t (t:make-term #:width 10 #:height 3)))
    (t:term-write! t "hello")
    (t:term-cursor-down! t 1) (t:term-carriage-return! t)
    (t:term-write! t "world")
    (t:term-selection-start! t 0 0)
    (t:term-selection-extend! t 4 0)
    (test-assert "cell (0,0) selected" (t:term-cell-selected? t 0 0))
    (test-assert "cell (4,0) selected" (t:term-cell-selected? t 4 0))
    (test-assert "cell (5,0) not selected"
                 (not (t:term-cell-selected? t 5 0)))
    (test-equal "selection text is 'hello'"
                "hello"
                (t:term-selection-text t))))

(test-group "block-mode selection clips to a rectangle"
  (let ((t (t:make-term #:width 10 #:height 3)))
    (t:term-write! t "abcdefghij")
    (t:term-cursor-down! t 1) (t:term-carriage-return! t)
    (t:term-write! t "ABCDEFGHIJ")
    (t:term-selection-start! t 2 0 'block)
    (t:term-selection-extend! t 4 1)
    (test-equal "block selection text"
                "cde\nCDE"
                (t:term-selection-text t))))

(test-group "clear drops the selection"
  (let ((t (t:make-term #:width 10 #:height 1)))
    (t:term-selection-start! t 0 0)
    (t:term-selection-extend! t 4 0)
    (test-assert "selection set" (t:term-selection t))
    (t:term-selection-clear! t)
    (test-assert "selection cleared" (not (t:term-selection t)))))

(test-end "term-selection")
