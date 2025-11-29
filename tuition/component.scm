;;; component.scm --- Component protocol for handling updates

(define-module (tuition component)
  #:use-module (oop goops)
  #:use-module (ice-9 receive)
  #:export (<component>
            component-update
            component-focused?
            component-focus!
            component-blur!
            try-component-update
            auto-delegate-to-components))

;;; Base component class
(define-class <component> ()
  (focused? #:init-value #f #:accessor component-focused?))

;;; Generic update method - components implement this
;;; Returns (values new-component handled?)
;;; - new-component: updated component state
;;; - handled?: #t if message was consumed, #f to bubble up
(define-generic component-update)

(define-method (component-update (c <component>) msg)
  "Default: don't handle any messages"
  (values c #f))

(define-method (component-focus! (c <component>))
  "Mark component as focused"
  (set! (component-focused? c) #t)
  c)

(define-method (component-blur! (c <component>))
  "Mark component as unfocused"
  (set! (component-focused? c) #f)
  c)

;;; Helper for delegating messages to components
(define* (try-component-update component msg #:key (check-focus? #t))
  "Try to update component with message. Returns (values component handled?).
   If check-focus? is #t (default), only delegates if component is focused.
   If component is not focused or doesn't handle the message, returns (values component #f)."
  (if (and check-focus? (not (component-focused? component)))
      (values component #f)
      (component-update component msg)))

;;; Auto-delegate messages to focused components in model
(define (auto-delegate-to-components model msg)
  "Walk through model slots, find focused components, try to delegate message.
   Returns (values new-model handled?)."
  (let ((model-class (class-of model)))
    (let loop ((slots (class-slots model-class))
               (handled? #f))
      (if (null? slots)
          (values model handled?)
          (let* ((slot (car slots))
                 (slot-name (slot-definition-name slot))
                 (value (slot-ref model slot-name)))
            (if (and (is-a? value <component>) (component-focused? value))
                (receive (new-component component-handled?)
                    (component-update value msg)
                  (slot-set! model slot-name new-component)
                  (if component-handled?
                      (values model #t)
                      (loop (cdr slots) handled?)))
                (loop (cdr slots) handled?)))))))
