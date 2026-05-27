(define-module (canary components progress)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary widget)
  #:use-module (oop goops)
  #:export (<progress>
            progress?
            progress
            progress-current
            progress-total
            progress-width
            progress-show-percent?
            progress-filled-face
            progress-empty-face
            progress-percent))

(define-class <progress> (<focusable>)
  (current       #:init-keyword #:current       #:init-value 0
                 #:getter progress-current)
  (total         #:init-keyword #:total         #:init-value 100
                 #:getter progress-total)
  (width         #:init-keyword #:width         #:init-value 40
                 #:getter progress-width)
  (show-percent? #:init-keyword #:show-percent? #:init-value #t
                 #:getter progress-show-percent?)
  (filled-face   #:init-keyword #:filled-face   #:init-value 'success
                 #:getter progress-filled-face)
  (empty-face    #:init-keyword #:empty-face    #:init-value 'dim
                 #:getter progress-empty-face))

(define (progress? x)
  "Return #t if X is a <progress>."
  (is-a? x <progress>))

(define (progress . args)
  "Return a fresh <progress> initialised from ARGS, a sequence of
#:current, #:total, #:width, #:show-percent?, #:filled-face,
#:empty-face keyword arguments."
  (apply make <progress> args))

(define (progress-percent p)
  "Return P's completion as an exact integer in [0, 100].  Returns 0
when total is zero."
  (let ((c (progress-current p)) (t (progress-total p)))
    (if (zero? t) 0 (inexact->exact (floor (* 100 (/ c t)))))))

(define-method (view (p <progress>))
  "Render <progress> P: bracketed bar of progress-width
cells, filled with █ in filled-face and ░ in empty-face, optionally
followed by a percent label."
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
