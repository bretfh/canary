(define-module (canary components progress)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (oop goops)
  #:export (<progress>
            progress?
            make-progress
            progress-current
            progress-total
            progress-width
            progress-show-percent?
            progress-filled-face
            progress-empty-face
            progress-percent))

(define-class <progress> ()
  (current       #:init-keyword #:current       #:init-value 0
                 #:accessor progress-current)
  (total         #:init-keyword #:total         #:init-value 100
                 #:accessor progress-total)
  (width         #:init-keyword #:width         #:init-value 40
                 #:accessor progress-width)
  (show-percent? #:init-keyword #:show-percent? #:init-value #t
                 #:accessor progress-show-percent?)
  (filled-face   #:init-keyword #:filled-face   #:init-value 'success
                 #:accessor progress-filled-face)
  (empty-face    #:init-keyword #:empty-face    #:init-value 'dim
                 #:accessor progress-empty-face))

(define (progress? x) (is-a? x <progress>))
(define (make-progress . args) (apply make <progress> args))

(define (progress-percent p)
  (let ((c (progress-current p)) (t (progress-total p)))
    (if (zero? t) 0 (inexact->exact (floor (* 100 (/ c t)))))))

(define-method (view (p <progress>) sz)
  (let* ((pct    (progress-percent p))
         (w      (progress-width p))
         (filled (inexact->exact (floor (* w (/ pct 100)))))
         (empty  (- w filled)))
    (apply hbox
           (txt "[")
           (txt (make-string filled #\█) #:fg (progress-filled-face p))
           (txt (make-string empty  #\░) #:fg (progress-empty-face  p))
           (txt "]")
           (if (progress-show-percent? p)
               (list (txt (string-append " " (number->string pct) "%")))
               '()))))
