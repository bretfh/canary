(define-module (canary components spinner)
  #:use-module (canary node)
  #:use-module (canary layout)
  #:use-module (canary protocol)
  #:export (<spinner-state>
            spinner?
            make-spinner
            spinner-tick!
            spinner-frame-idx
            spinner-face
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

(define-node spinner
  #:state ((frames spinner-dots)
           (frame-idx 0)
           (face 'accent))
  #:view (lambda (s)
           (let ((fr (spinner-frames s)))
             (txt (list-ref fr (modulo (spinner-frame-idx s) (length fr)))
                  #:fg (spinner-face s))))
  #:react (lambda (s msg)
            (when (tick? msg)
              (set! (spinner-frame-idx s (+ 1 (spinner-frame-idx s))))))

(define (spinner-tick! s)
  (set! (spinner-frame-idx s (+ 1 (spinner-frame-idx s))))
