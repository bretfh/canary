(define-module (gcell components spinner)
  #:use-module (gcell view)
  #:use-module (gcell layout)
  #:use-module (gcell protocol)
  #:use-module (gcell widget)
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

(define-class <spinner> (<focusable>)
  (frames    #:init-keyword #:frames    #:init-value spinner-dots
             #:getter spinner-frames)
  (frame-idx #:init-keyword #:frame-idx #:init-value 0
             #:getter spinner-frame-idx)
  (face      #:init-keyword #:face      #:init-value 'accent
             #:getter spinner-face)
  (hz        #:init-keyword #:hz        #:init-value 10
             #:getter spinner-hz))

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
  (cons s (every #:hz (spinner-hz s)
                 #:id  (list 'spinner-tick (widget-id s))
                 (lambda () (tick)))))

(define-method (update (s <spinner>) (msg <tick>))
  "Advance the frame index."
  (cons (update-slots s #:frame-idx (+ 1 (spinner-frame-idx s))) #f))
