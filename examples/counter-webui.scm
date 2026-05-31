;;; counter-webui.scm
;;;
;;; Same widget as counter.scm, but uses the webui backend so the
;;; gcell cell grid renders into a browser window via WebGL.
;;;
;;; Run: LD_LIBRARY_PATH=/path/to/libwebui guile -L /path/to/gcell \
;;;        -L /path/to/guile-webui examples/counter-webui.scm
;;; Keys: + or k -- increment; - or j -- decrement; r -- reset; q -- quit.

(use-modules (gcell)
             (gcell backend-webui)
             (oop goops))

(define-class <counter> (<focusable>)
  (n #:init-keyword #:n #:init-value 0 #:getter counter-n))

(define-method (view (c <counter>))
  (vbox (txt "  press + or - (q to quit)" #:fg 'muted)
        (spacer 1)
        (align (txt (number->string (counter-n c))
                    #:fg 'accent #:bold)
               #:h 'center #:width 40)))

(define-method (update (c <counter>) (msg <key>))
  (let ((k (key-sym msg)))
    (cons
     (cond
      ((or (eqv? k #\+) (eqv? k #\k))
       (update-slots c #:n (+ 1 (counter-n c))))
      ((or (eqv? k #\-) (eqv? k #\j))
       (update-slots c #:n (- (counter-n c) 1)))
      ((eqv? k #\r) (update-slots c #:n 0))
      (else c))
     #f)))

(run-app (make <counter>)
         #:title   "counter (webui)"
         #:backend (webui-backend)
         #:keymap  (keymap (bind #\q 'quit) (bind 'escape 'quit))
         #:mouse   'off)
