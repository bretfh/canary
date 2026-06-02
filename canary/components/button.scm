(define-module (canary components button)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary borders)
  #:use-module (canary widget)
  #:use-module (oop goops)
  #:export (<button>
            button?
            button
            button-label
            button-action
            button-face
            button-focused-face
            button-focused?
            button-border))

(define-class <button> (<focusable>)
  (label        #:init-keyword #:label        #:init-value ""
                #:getter button-label)
  (action       #:init-keyword #:action       #:init-value #f
                #:getter button-action)
  (face         #:init-keyword #:face         #:init-value 'muted
                #:getter button-face)
  (focused-face #:init-keyword #:focused-face #:init-value 'accent
                #:getter button-focused-face)
  (focused?     #:init-keyword #:focused?     #:init-value #f
                #:getter button-focused?)
  (border       #:init-keyword #:border       #:init-value border-rounded
                #:getter button-border))

(define (button? x)
  "Return #t if X is a <button>."
  (is-a? x <button>))

(define (button . args)
  "Return a fresh <button> initialised from ARGS, a sequence of
#:label, #:action, #:face, #:focused-face, #:focused?, #:border
keyword arguments."
  (apply make <button> args))

(define-method (view (b <button>))
  "Render <button> B: a bordered label whose face flips to
button-focused-face when B is focused, wrapped in `on-click` so
the configured action fires on press."
  (let* ((focused? (button-focused? b))
         (face     (if focused? (button-focused-face b) (button-face b))))
    (on-click
     (boxed (txt (string-append " " (button-label b) " ")
                 #:fg face #:bold focused?)
            #:border (button-border b)
            #:fg     face)
     #:action (button-action b))))
