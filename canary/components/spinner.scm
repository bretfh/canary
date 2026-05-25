(define-module (canary components spinner)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary protocol)
  #:use-module (oop goops)
  #:export (<spinner>
            spinner?
            make-spinner
            spinner-stop!
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

(define (make-spinner . args)
  "Return a fresh <spinner> initialised from ARGS, a sequence of
#:frames, #:frame-idx, #:face, #:hz keyword arguments."
  (apply make <spinner> args))

(define-method (view (s <spinner>) sz)
  "Render <spinner> S at size SZ: the current frame from S's frame
list, drawn in the spinner's face."
  (let ((fr (spinner-frames s)))
    (txt (list-ref fr (modulo (spinner-frame-idx s) (length fr)))
         #:fg (spinner-face s))))

(define-method (update (s <spinner>) msg sz)
  "React to MSG for <spinner> S.  On <init>, install a periodic
ticker tagged with S so `spinner-stop!` can later cancel it.  On
each <tick>, advance the frame index.  Returns two values: the
updated spinner and an optional cmd."
  (cond
   ((init? msg)
    (values s (every #:hz (spinner-hz s)
                     #:id  (list 'spinner-tick s)
                     (lambda () (tick)))))
   ((tick? msg)
    (set! (spinner-frame-idx s) (+ 1 (spinner-frame-idx s)))
    (values s #f))
   (else (values s #f))))

(define (spinner-stop! s)
  "Cancel a spinner's installed ticker. Use when removing a spinner
from the tree to free its fiber."
  (cancel (list 'spinner-tick s)))
