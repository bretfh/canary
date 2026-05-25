(define-module (canary components viewport)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary protocol)
  #:use-module (canary key)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<viewport>
            viewport?
            make-viewport
            viewport-items
            viewport-offset
            viewport-step
            viewport-tail?
            viewport-scroll-up!
            viewport-scroll-down!
            viewport-scroll-to-end!
            viewport-scroll-to-start!))

(define-class <viewport> ()
  (items   #:init-keyword #:items   #:init-value '() #:accessor viewport-items)
  (offset  #:init-keyword #:offset  #:init-value 0   #:accessor viewport-offset)
  (step    #:init-keyword #:step    #:init-value 1   #:accessor viewport-step)
  ;; tail?: when #t, view always shows the LAST visible-rows items
  ;; (auto-scrolls to end as new items are appended). When #f, view
  ;; shows items starting at offset.
  (tail?   #:init-keyword #:tail?   #:init-value #f  #:accessor viewport-tail?))

(define (viewport? x)
  "Return #t if X is a <viewport>."
  (is-a? x <viewport>))

(define (make-viewport . args)
  "Return a fresh <viewport> initialised from ARGS, a sequence of
#:items, #:offset, #:step, #:tail? keyword arguments."
  (apply make <viewport> args))

(define (viewport-scroll-up! v)
  "Scroll V up by its configured step.  Leaves tail mode if it was
active.  Returns V."
  (set! (viewport-tail? v) #f)
  (set! (viewport-offset v) (max 0 (- (viewport-offset v) (viewport-step v))))
  v)

(define (viewport-scroll-down! v)
  "Scroll V down by its configured step, clamped to the item count.
Leaves tail mode if it was active.  Returns V."
  (set! (viewport-tail? v) #f)
  (let ((n (length (viewport-items v))))
    (set! (viewport-offset v) (min (max 0 (- n 1))
                                   (+ (viewport-offset v) (viewport-step v)))))
  v)

(define (viewport-scroll-to-start! v)
  "Jump V to offset 0.  Leaves tail mode if it was active.  Returns V."
  (set! (viewport-tail? v) #f)
  (set! (viewport-offset v) 0)
  v)

(define (viewport-scroll-to-end! v)
  "Jump V to the last item and enter tail mode so future appends
auto-scroll into view.  Returns V."
  (set! (viewport-tail? v) #t)
  (set! (viewport-offset v) (max 0 (- (length (viewport-items v)) 1)))
  v)

(define-method (view (v <viewport>) sz)
  "Render <viewport> V at size SZ: a vbox of the items visible in
the window of SZ's height starting at offset, or the last window
when tail? is true.  The view is clipped to the window height so
view-size reports exactly the visible footprint (required for flex
sizing — without clipping, scrolled history would steal space from
siblings)."
  (let* ((items (viewport-items v))
         (n (length items))
         (h (max 1 (size-height sz)))
         (start (cond
                 ((viewport-tail? v) (max 0 (- n h)))
                 (else (max 0 (min (viewport-offset v) (max 0 (- n 1)))))))
         (after-start (if (>= start n) '() (list-tail items start)))
         ;; Clip to h items so the widget's view-size reports exactly
         ;; the visible window size on the major axis. Critical for the
         ;; flex measure pass: without clipping, scrolled-into-history
         ;; modes report (n - offset) as the intrinsic, which lets the
         ;; history pane consume the entire vbox and push siblings off.
         (visible (let lp ((rem after-start) (acc '()) (k 0))
                    (cond
                     ((or (null? rem) (>= k h)) (reverse acc))
                     (else (lp (cdr rem) (cons (car rem) acc) (+ k 1)))))))
    (cond
     ((null? visible) (txt ""))
     (else (apply vbox visible)))))

(define-method (update (v <viewport>) (msg <key>) sz)
  "React to key MSG for <viewport> V.  Up / k scrolls up; down / j
scrolls down, re-entering tail mode if it reaches the end; home
jumps to the start; end pins to tail.  Returns two values: V
(mutated in place) and #f (no cmd)."
  (let* ((k (key-sym msg))
         (h (max 1 (size-height sz)))
         (n (length (viewport-items v)))
         (tail-offset (max 0 (- n h)))     ; offset that corresponds to "anchored to end"
         (step (viewport-step v)))
    (define (leave-tail!)
      (when (viewport-tail? v)
        (set! (viewport-offset v) tail-offset)
        (set! (viewport-tail? v) #f)))
    (cond
     ((or (eq? k 'up) (eqv? k #\k))
      (leave-tail!)
      (set! (viewport-offset v) (max 0 (- (viewport-offset v) step))))
     ((or (eq? k 'down) (eqv? k #\j))
      (cond
       ((viewport-tail? v) #f)              ; already pinned to end
       (else
        (let ((new (min (max 0 (- n 1))
                        (+ (viewport-offset v) step))))
          (set! (viewport-offset v) new)
          ;; Reached the tail → re-enter auto-follow mode.
          (when (>= new tail-offset)
            (set! (viewport-tail? v) #t))))))
     ((eq? k 'home)
      (leave-tail!)
      (set! (viewport-offset v) 0))
     ((eq? k 'end)
      (set! (viewport-tail? v) #t))))
  (values v #f))
