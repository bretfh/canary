;;; components/spinner.scm --- Animated spinner

(define-module (tuition components spinner)
  #:use-module (tuition style)
  #:use-module (srfi srfi-9)
  #:export (<spinner>
            spinner?
            make-spinner
            spinner-tick!
            spinner-render
            spinner-dots
            spinner-line
            spinner-circle
            spinner-moon
            spinner-arrow))

;;; Spinner record
(define-record-type <spinner>
  (%make-spinner frames frame-idx)
  spinner?
  (frames spinner-frames)
  (frame-idx spinner-frame-idx set-spinner-frame-idx!))

;;; Predefined spinner styles
(define spinner-dots
  '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"))

(define spinner-line
  '("-" "\\" "|" "/"))

(define spinner-circle
  '("◐" "◓" "◑" "◒"))

(define spinner-moon
  '("🌑" "🌒" "🌓" "🌔" "🌕" "🌖" "🌗" "🌘"))

(define spinner-arrow
  '("←" "↖" "↑" "↗" "→" "↘" "↓" "↙"))

(define* (make-spinner #:key (frames spinner-dots))
  "Create a new spinner"
  (%make-spinner (list->vector frames) 0))

(define (spinner-tick! spinner)
  "Advance spinner to next frame"
  (let* ((frames (spinner-frames spinner))
         (idx (spinner-frame-idx spinner))
         (next-idx (modulo (1+ idx) (vector-length frames))))
    (set-spinner-frame-idx! spinner next-idx)
    spinner))

(define (spinner-render spinner)
  (let ((frames (spinner-frames spinner))
        (idx (spinner-frame-idx spinner)))
    (vector-ref frames idx)))
