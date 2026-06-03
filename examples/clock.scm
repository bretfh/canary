;;; clock.scm — digital clock; ticks once per second.
;;;
;;; Run: guile -L /path/to/guile-canary examples/clock.scm
;;; Keys: q — quit.

(use-modules (canary) (oop goops)
             (canary backend-webui))

(define (now-string)
  (strftime "%H:%M:%S" (localtime (current-time))))

(define-component <clock>
  (time #:init-form (now-string)
        #:getter    clock-time))

(define-method (view (c <clock>))
  (vbox (txt "  digital clock (q to quit)" #:fg 'muted)
        (spacer 1)
        (align (txt (clock-time c) #:fg 'accent #:bold)
               #:h 'center #:width 40)))

(define-method (update (c <clock>) (msg <mount>))
  (cons c (every #:hz 1 tick)))

(define-method (update (c <clock>) (msg <tick>))
  (cons (update-slots c #:time (now-string)) #f))

(run-app (make <clock>)
         #:backend (webui-backend)
         #:title  "clock"
         #:keymap (keymap (bind #\q 'quit) (bind 'escape 'quit))
         #:mouse  'off)
