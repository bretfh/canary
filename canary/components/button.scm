(define-module (canary components button)
  #:use-module (canary node)
  #:use-module (canary layout)
  #:use-module (canary borders)
  #:export (<button-state>
            button?
            make-button
            button-label
            button-action
            button-face
            button-focused-face
            button-focused?
            button-border))

(define-node button
  #:state ((label "")
           (action #f)
           (face 'muted)
           (focused-face 'accent)
           (focused? #f)
           (border border-rounded))
  #:view
  (lambda (b)
    (let* ((focused? (button-focused? b))
           (face     (if focused? (button-focused-face b) (button-face b))))
      (on-click
       (button-action b)
       (boxed (txt (string-append " " (button-label b) " ")
                   #:fg face #:bold focused?)
              #:border (button-border b)
              #:fg     face)))))
