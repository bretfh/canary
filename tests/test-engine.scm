(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (canary view)
             (canary layout)
             (canary protocol)
             (canary render)
             (canary draw)
             (oop goops))

(test-begin "engine")

(define-class <tape> ()
  (seen #:init-value '() #:accessor tape-seen))

(define-method (view (t <tape>) sz) (txt "tape"))

(define-method (update (t <tape>) msg sz)
  (set! (tape-seen t) (cons msg (tape-seen t)))
  (values t #f))

(let ((t (make <tape>)))
  (update t 'a #f)
  (update t 'b #f)
  (update t 'c #f)
  (test-equal "update receives msgs in order"
    '(a b c) (reverse (tape-seen t))))

(define-class <ticker> ()
  (installed? #:init-value #f #:accessor ticker-installed?))

(define-method (view (n <ticker>) sz) (txt "tk"))

(define-method (update (n <ticker>) msg sz)
  (cond
   ((init? msg)
    (set! (ticker-installed? n) #t)
    (values n 'pretend-cmd))
   (else (values n #f))))

(let ((n (make <ticker>)))
  (call-with-values (lambda () (update n (init) #f))
    (lambda (n2 cmd)
      (test-equal  "init returns cmd"   'pretend-cmd cmd)
      (test-assert "init mutated state" (ticker-installed? n)))))

(define-class <point> ()
  (x #:init-keyword #:x #:init-value 0 #:accessor point-x)
  (y #:init-keyword #:y #:init-value 0 #:accessor point-y))

(let ((p (make <point> #:x 3 #:y 4)))
  (test-equal "x slot" 3 (point-x p))
  (test-equal "y slot" 4 (point-y p))
  (set! (point-x p) 10)
  (test-equal "set! (point-x p) writes" 10 (point-x p)))

(let* ((tree (vbox (txt "header") (txt "footer") (make <tape>)))
       (cmds (render tree 20 10))
       (texts (filter-map (lambda (c) (and (text-cmd? c) (text-str c))) cmds)))
  (test-equal "vbox with stateful renders all"
    '("header" "footer" "tape")
    texts))

(test-end "engine")
