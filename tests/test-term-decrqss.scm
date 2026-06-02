(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (srfi srfi-13)
             ((canary term types)  #:prefix t:)
             ((canary term ops)    #:prefix t:)
             ((canary term parser) #:prefix t:))

(define (reply-of input)
  (let ((box (list #f)))
    (let ((t (t:make-term
              #:width 10 #:height 24
              #:input-fn
              (lambda (term reply) (set-car! box reply)))))
      (t:term-process-output! t input)
      (car box))))

(test-begin "term-decrqss")

(test-group "DECRQSS for DECSTBM reports the scroll region"
  (let* ((t (t:make-term
             #:width 10 #:height 24
             #:input-fn (lambda (term reply) reply))))
    (t:term-set-scroll-region! t 5 20)
    (let ((box (list #f)))
      (t:set-term-input-fn! t (lambda (term reply) (set-car! box reply)))
      (t:term-process-output! t "\x1bP$qr\x1b\\")
      (test-assert "reply has the DECRQSS prefix"
                   (string-contains (car box)
                                    (string-append (string #\esc) "P1$r")))
      (test-assert "reply contains 5;20r"
                   (string-contains (car box) "5;20r")))))

(test-group "DECRQSS for DECSCUSR reports the cursor style"
  (let* ((reply (reply-of "\x1bP$q q\x1b\\")))
    (test-assert "reply present" reply)
    (test-assert "reply contains a steady-block code"
                 (string-contains reply "2 q"))))

(test-group "DECRQSS for an unknown query is silent"
  (let ((reply (reply-of "\x1bP$qXYZ\x1b\\")))
    (test-assert "no reply" (not reply))))

(test-end "term-decrqss")
