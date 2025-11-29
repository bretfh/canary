;;; mouse.scm --- Mouse event handling

(define-module (tuition mouse)
  #:use-module (srfi srfi-9)
  #:use-module (oop goops)
  #:export (mouse-event?
            mouse-click-event?
            mouse-drag-event?
            mouse-scroll-event?
            mouse-event-x
            mouse-event-y
            mouse-event-button
            mouse-event-shift?
            mouse-event-alt?
            mouse-event-ctrl?
            mouse-scroll-direction
            make-mouse-click-event
            make-mouse-drag-event
            make-mouse-scroll-event))

;;; Mouse event classes
(define-class <mouse-event> ()
  (x #:init-keyword #:x #:getter mouse-event-x)
  (y #:init-keyword #:y #:getter mouse-event-y)
  (shift? #:init-keyword #:shift? #:init-value #f #:getter mouse-event-shift?)
  (alt? #:init-keyword #:alt? #:init-value #f #:getter mouse-event-alt?)
  (ctrl? #:init-keyword #:ctrl? #:init-value #f #:getter mouse-event-ctrl?))

(define-class <mouse-click-event> (<mouse-event>)
  (button #:init-keyword #:button #:getter mouse-event-button))  ; 'left 'right 'middle

(define-class <mouse-drag-event> (<mouse-event>)
  (button #:init-keyword #:button #:getter mouse-event-button))

(define-class <mouse-scroll-event> (<mouse-event>)
  (direction #:init-keyword #:direction #:getter mouse-scroll-direction))  ; 'up 'down

(define (mouse-event? obj)
  (is-a? obj <mouse-event>))

(define (mouse-click-event? obj)
  (is-a? obj <mouse-click-event>))

(define (mouse-drag-event? obj)
  (is-a? obj <mouse-drag-event>))

(define (mouse-scroll-event? obj)
  (is-a? obj <mouse-scroll-event>))

(define* (make-mouse-click-event #:key x y button (shift? #f) (alt? #f) (ctrl? #f))
  (make <mouse-click-event> #:x x #:y y #:button button
        #:shift? shift? #:alt? alt? #:ctrl? ctrl?))

(define* (make-mouse-drag-event #:key x y button (shift? #f) (alt? #f) (ctrl? #f))
  (make <mouse-drag-event> #:x x #:y y #:button button
        #:shift? shift? #:alt? alt? #:ctrl? ctrl?))

(define* (make-mouse-scroll-event #:key x y direction (shift? #f) (alt? #f) (ctrl? #f))
  (make <mouse-scroll-event> #:x x #:y y #:direction direction
        #:shift? shift? #:alt? alt? #:ctrl? ctrl?))
