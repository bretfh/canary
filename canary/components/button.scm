(define-module (canary components button)
  #:use-module (canary layout)
  #:use-module (canary borders)
  #:use-module (canary component)
  #:use-module (oop goops)
  #:export (<button>
            make-button
            button?
            button-label
            button-action
            button-view))

(define-class <button> (<component>)
  (label    #:init-keyword #:label    #:init-value "" #:accessor button-label)
  (action   #:init-keyword #:action   #:init-value #f #:accessor button-action)
  (face     #:init-keyword #:face     #:init-value 'muted  #:accessor button-face)
  (focused-face #:init-keyword #:focused-face #:init-value 'accent
                #:accessor button-focused-face)
  (border   #:init-keyword #:border   #:init-value border-rounded
            #:accessor button-border))

(define (button? x) (is-a? x <button>))

(define* (make-button #:key label action (face 'muted) (focused-face 'accent)
                      (border border-rounded))
  (make <button>
    #:label label
    #:action action
    #:face face
    #:focused-face focused-face
    #:border border))

(define (button-view b)
  "Render the button as an on-click region around a boxed label.  Border
and label colour switch on focus state."
  (let ((focused? (component-focused? b))
        (lbl      (button-label b)))
    (on-click
     (button-action b)
     (boxed (txt (string-append " " lbl " ")
                 #:fg (if focused? (button-focused-face b) (button-face b))
                 #:bold focused?)
            #:border (button-border b)
            #:fg (if focused? (button-focused-face b) (button-face b))))))
