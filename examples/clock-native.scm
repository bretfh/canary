;;; clock-native.scm — clock running on the native (glfw+freetype+GL) backend.
;;;
;;; Run from canary's root, inside a guix shell that provides glfw +
;;; freetype + libepoxy + font-dejavu:
;;;
;;;   CANARY_NATIVE_FONT_DIR=$(guix build font-dejavu)/share/fonts/truetype \
;;;     guile -L . -L ../guile-webui examples/clock-native.scm
;;;
;;; Keys: q — quit.

(use-modules (canary) (oop goops)
             (canary backend-native))

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
         #:backend (native-backend)
         #:title  "clock (native)"
         #:keymap (keymap (bind #\q 'quit) (bind 'escape 'quit))
         #:mouse  'off)
