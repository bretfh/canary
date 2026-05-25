(define-module (canary components button)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary borders)
  #:use-module (oop goops)
  #:export (<button>
            button?
            make-button
            button-label
            button-action
            button-face
            button-focused-face
            button-focused?
            button-border))

(define-class <button> ()
  (label        #:init-keyword #:label        #:init-value ""
                #:accessor button-label)
  (action       #:init-keyword #:action       #:init-value #f
                #:accessor button-action)
  (face         #:init-keyword #:face         #:init-value 'muted
                #:accessor button-face)
  (focused-face #:init-keyword #:focused-face #:init-value 'accent
                #:accessor button-focused-face)
  (focused?     #:init-keyword #:focused?     #:init-value #f
                #:accessor button-focused?)
  (border       #:init-keyword #:border       #:init-value border-rounded
                #:accessor button-border))

(define (button? x) (is-a? x <button>))
(define (make-button . args) (apply make <button> args))

(define-method (view (b <button>) sz)
  (let* ((focused? (button-focused? b))
         (face     (if focused? (button-focused-face b) (button-face b))))
    (on-click
     (button-action b)
     (boxed (txt (string-append " " (button-label b) " ")
                 #:fg face #:bold focused?)
            #:border (button-border b)
            #:fg     face))))
