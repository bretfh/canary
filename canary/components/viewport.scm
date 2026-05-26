(define-module (canary components viewport)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary protocol)
  #:use-module (canary key)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<viewport>
            viewport?
            viewport
            viewport-items
            viewport-offset
            viewport-step
            viewport-from
            viewport-height
            viewport-scroll-up!
            viewport-scroll-down!
            viewport-scroll-to-start!
            viewport-scroll-to-end!))

(define-class <viewport> ()
  (items  #:init-keyword #:items  #:init-value '()   #:accessor viewport-items)
  (offset #:init-keyword #:offset #:init-value 0     #:accessor viewport-offset)
  (step   #:init-keyword #:step   #:init-value 1     #:accessor viewport-step)
  (from   #:init-keyword #:from   #:init-value 'top  #:accessor viewport-from)
  (height #:init-keyword #:height #:init-value #f    #:accessor viewport-height))

(define (viewport? x) (is-a? x <viewport>))

(define (viewport . args) (apply make <viewport> args))

(define (viewport-scroll-up! v)
  (let ((n (length (viewport-items v)))
        (step (viewport-step v)))
    (set! (viewport-offset v)
          (case (viewport-from v)
            ((bottom) (min (max 0 n) (+ (viewport-offset v) step)))
            (else     (max 0 (- (viewport-offset v) step))))))
  v)

(define (viewport-scroll-down! v)
  (let ((n (length (viewport-items v)))
        (step (viewport-step v)))
    (set! (viewport-offset v)
          (case (viewport-from v)
            ((bottom) (max 0 (- (viewport-offset v) step)))
            (else     (min (max 0 (- n 1)) (+ (viewport-offset v) step))))))
  v)

(define (viewport-scroll-to-start! v)
  (set! (viewport-offset v)
        (case (viewport-from v)
          ((bottom) (length (viewport-items v)))
          (else     0)))
  v)

(define (viewport-scroll-to-end! v)
  (set! (viewport-offset v)
        (case (viewport-from v)
          ((bottom) 0)
          (else     (max 0 (- (length (viewport-items v)) 1)))))
  v)

(define-method (view (v <viewport>))
  (let* ((items (viewport-items v))
         (n     (length items))
         (off   (viewport-offset v))
         (h     (viewport-height v)))
    (case (viewport-from v)
      ((bottom)
       (let* ((keep   (max 0 (- n off)))
              (window (if h (min keep h) keep))
              (start  (max 0 (- keep window))))
         (cond
          ((zero? window) (txt ""))
          (else (apply vbox (list-head (list-tail items start) window))))))
      (else
       (let* ((off*   (max 0 (min off (max 0 (- n 1)))))
              (avail  (max 0 (- n off*)))
              (window (if h (min avail h) avail)))
         (cond
          ((zero? n)      (txt ""))
          ((>= off* n)    (txt ""))
          ((zero? window) (txt ""))
          (else (apply vbox (list-head (list-tail items off*) window)))))))))

(define-method (update (v <viewport>) (msg <key>))
  (let ((k (key-sym msg)))
    (cond
     ((or (eq? k 'up)   (eqv? k #\k)) (viewport-scroll-up!   v))
     ((or (eq? k 'down) (eqv? k #\j)) (viewport-scroll-down! v))
     ((eq? k 'home) (viewport-scroll-to-start! v))
     ((eq? k 'end)  (viewport-scroll-to-end!   v))))
  (values v #f))
