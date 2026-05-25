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

(define (spinner? x) (is-a? x <spinner>))
(define (make-spinner . args) (apply make <spinner> args))

(define-method (view (s <spinner>) sz)
  (let ((fr (spinner-frames s)))
    (txt (list-ref fr (modulo (spinner-frame-idx s) (length fr)))
         #:fg (spinner-face s))))

(define-method (update (s <spinner>) msg sz)
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
