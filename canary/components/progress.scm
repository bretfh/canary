(define-module (canary components progress)
  #:use-module (canary node)
  #:use-module (canary layout)
  #:export (<progress-state>
            progress?
            make-progress
            progress-current
            progress-total
            progress-width
            progress-show-percent?
            progress-filled-face
            progress-empty-face
            progress-percent))

(define-node progress
  #:state ((current 0)
           (total 100)
           (width 40)
           (show-percent? #t)
           (filled-face 'success)
           (empty-face 'dim))
  #:view (lambda (p)
           (let* ((pct (progress-percent p))
                  (w (progress-width p))
                  (filled (inexact->exact (floor (* w (/ pct 100)))))
                  (empty (- w filled)))
             (apply hbox
                    (txt "[")
                    (txt (make-string filled #\█) #:fg (progress-filled-face p))
                    (txt (make-string empty  #\░) #:fg (progress-empty-face p))
                    (txt "]")
                    (if (progress-show-percent? p)
                        (list (txt (string-append " " (number->string pct) "%")))
                        '())))))

(define (progress-percent p)
  (let ((c (progress-current p)) (t (progress-total p)))
    (if (zero? t) 0 (inexact->exact (floor (* 100 (/ c t)))))))
