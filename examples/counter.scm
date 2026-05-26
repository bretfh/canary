;;; counter.scm — hello-world for canary.
;;;
;;; Run: guile -L /path/to/guile-canary examples/counter.scm
;;; Keys: + or k — increment; - or j — decrement; r — reset; q — quit.

(use-modules (canary) (oop goops))

(define-class <counter> ()
  (n #:init-keyword #:n #:init-value 0 #:accessor counter-n))

(define-method (view (c <counter>))
  (vbox (txt "  press + or - (q to quit)" #:fg 'muted)
        (spacer 1)
        (align (txt (number->string (counter-n c))
                    #:fg 'accent #:bold)
               #:h 'center #:width 40)))

(define-method (update (c <counter>) (msg <key>))
  (let ((k (key-sym msg)))
    (cond
     ((or (eqv? k #\+) (eqv? k #\k))
      (set! (counter-n c) (+ 1 (counter-n c))))
     ((or (eqv? k #\-) (eqv? k #\j))
      (set! (counter-n c) (- (counter-n c) 1)))
     ((eqv? k #\r) (set! (counter-n c) 0)))))

(run-app (make <counter>)
         #:title  "counter"
         #:keymap (keymap (bind #\q 'quit) (bind 'escape 'quit))
         #:mouse  'off)
