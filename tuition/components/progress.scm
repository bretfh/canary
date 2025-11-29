;;; components/progress.scm --- Progress bar component

(define-module (tuition components progress)
  #:use-module (tuition style)
  #:use-module (srfi srfi-9)
  #:export (<progress>
            progress?
            make-progress
            progress-set!
            progress-render
            progress-percent))

;;; Progress bar record
(define-record-type <progress>
  (%make-progress current total width show-percent?)
  progress?
  (current progress-current set-progress-current!)
  (total progress-total)
  (width progress-width)
  (show-percent? progress-show-percent?))

(define* (make-progress #:key (current 0) (total 100) (width 40) (show-percent? #t))
  "Create a new progress bar"
  (%make-progress current total width show-percent?))

(define (progress-set! progress value)
  "Set progress value"
  (set-progress-current! progress value)
  progress)

(define (progress-percent progress)
  "Get progress as percentage"
  (let ((cur (progress-current progress))
        (tot (progress-total progress)))
    (if (zero? tot)
        0
        (inexact->exact (floor (* 100 (/ cur tot)))))))

(define (progress-render progress)
  "Render progress bar"
  (let* ((percent (progress-percent progress))
         (width (progress-width progress))
         (filled (inexact->exact (floor (* width (/ percent 100)))))
         (empty (- width filled))
         (bar-filled (make-string filled #\█))
         (bar-empty (make-string empty #\░))
         (bar (string-append (fg bar-filled 2) (fg bar-empty 8)))
         (percent-str (if (progress-show-percent? progress)
                         (string-append " " (number->string percent) "%")
                         "")))
    (string-append "[" bar "]" percent-str)))
