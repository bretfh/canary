;;; evdev-keys.scm — show raw kernel input events as canary keys.
;;;
;;; Run: guile -L /path/to/guile-canary examples/evdev-keys.scm
;;; Needs read access to /dev/input/event* (input group or root).
;;; Keys: q — quit.  Everything else — displayed with its event type
;;; and held modifiers, including releases and gamepad buttons no
;;; terminal would ever forward.

(use-modules (canary) (oop goops))

(define-component <key-show>
  (last #:init-value #f #:getter key-show-last)
  (seen #:init-value 0  #:getter key-show-seen))

(define (describe k)
  (format #f "~a  [~a]~a"
          (key->string k)
          (key-event k)
          (if (null? (key-mods k))
              ""
              (format #f "  mods: ~a" (key-mods k)))))

(define-method (view (w <key-show>))
  (vbox (txt "  evdev input (q to quit)" #:fg 'muted)
        (spacer 1)
        (boxed
         (align (txt (if (key-show-last w)
                         (describe (key-show-last w))
                         "press any key or button...")
                     #:fg 'accent #:bold)
                #:h 'center #:width 60)
         #:title (format #f " ~a events " (key-show-seen w)))))

(define-method (update (w <key-show>) (msg <key>))
  (cons (update-slots w
          #:last msg
          #:seen (+ 1 (key-show-seen w)))
        #f))

(format #t "key-capable devices: ~a~%" (evdev-devices))

(run-app (make <key-show>)
         #:title  "evdev-keys"
         #:keymap (keymap (bind #\q 'quit))
         #:evdev  #t)
