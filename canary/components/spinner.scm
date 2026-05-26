(define-module (canary components spinner)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary protocol)
  #:use-module (oop goops)
  #:export (<spinner>
            spinner?
            spinner
            spinner-frame-idx
            spinner-face
            spinner-hz
            spinner-frames
            spinner-dots
            spinner-line
            spinner-circle
            spinner-moon
            spinner-arrow))

(define spinner-dots   '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"))
(define spinner-line   '("-" "\\" "|" "/"))
(define spinner-circle '("◐" "◓" "◑" "◒"))
(define spinner-moon   '("🌑" "🌒" "🌓" "🌔" "🌕" "🌖" "🌗" "🌘"))
(define spinner-arrow  '("←" "↖" "↑" "↗" "→" "↘" "↓" "↙"))

(define-class <spinner> ()
  (frames    #:init-keyword #:frames    #:init-value spinner-dots
             #:accessor spinner-frames)
  (frame-idx #:init-keyword #:frame-idx #:init-value 0
             #:accessor spinner-frame-idx)
  (face      #:init-keyword #:face      #:init-value 'accent
             #:accessor spinner-face)
  (hz        #:init-keyword #:hz        #:init-value 10
             #:accessor spinner-hz))

(define (spinner? x)
  "Return #t if X is a <spinner>."
  (is-a? x <spinner>))

(define (spinner . args)
  "Return a fresh <spinner> initialised from ARGS, a sequence of
#:frames, #:frame-idx, #:face, #:hz keyword arguments."
  (apply make <spinner> args))

(define-method (view (s <spinner>))
  "Render <spinner> S: the current frame from S's frame list,
drawn in the spinner's face."
  (let ((fr (spinner-frames s)))
    (txt (list-ref fr (modulo (spinner-frame-idx s) (length fr)))
         #:fg (spinner-face s))))

(define-method (update (s <spinner>) (msg <mount>))
  "On mount, install a periodic ticker tagged with S; the engine
auto-cancels it on <unmount>."
  (every #:hz (spinner-hz s)
         #:id  (list 'spinner-tick s)
         (lambda () (tick))))

(define-method (update (s <spinner>) (msg <tick>))
  "Advance the frame index."
  (set! (spinner-frame-idx s) (+ 1 (spinner-frame-idx s))))
