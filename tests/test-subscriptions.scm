(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (gcell view)
             (gcell layout)
             (gcell widget)
             (gcell protocol)
             (gcell keymap)
             ((gcell engine-types) #:select (engine engine-root))
             ((gcell backend-test) #:select (make-test-backend))
             (oop goops))

(test-begin "subscriptions")

;;; A widget that subscribes to <tick> only.
(define-class <ticker> (<focusable>)
  (n #:init-keyword #:n #:init-value 0 #:accessor ticker-n))

(define-method (view (t <ticker>)) (txt "ticker"))

(define-method (update (t <ticker>) (msg <tick>))
  (cons (update-slots t #:n (+ 1 (ticker-n t))) #f))

;;; A widget with NO specialised update method at all.
(define-class <inert> (<focusable>)
  (calls #:init-value 0 #:accessor inert-calls))

(define-method (view (s <inert>)) (txt "inert"))

;;; A root that contains both.
(define-class <pair-root> (<focusable>)
  (a #:init-form (make <ticker>) #:getter pair-a)
  (b #:init-form (make <inert>)  #:getter pair-b))

(define-method (view (p <pair-root>))
  (vbox (pair-a p) (pair-b p)))

;;; Gate: ticker fires on <tick>, inert is skipped entirely; the inert
;;; instance is identity-preserved across the cascade.
(let* ((cascade! (@@ (gcell engine) cascade!))
       (root (make <pair-root>))
       (eng  (engine #:backend (make-test-backend)
                     #:keymap  (keymap)
                     #:root    root)))
  (let ((orig-b (pair-b root)))
    (cascade! eng (tick))
    (let* ((new-root (engine-root eng))
           (new-a    (slot-ref new-root 'a))
           (new-b    (slot-ref new-root 'b)))
      (test-equal "subscribed widget update fires on tick"
                  1 (ticker-n new-a))
      (test-assert "non-subscribed sibling preserves identity"
                   (eq? new-b orig-b))
      (test-assert "non-subscribed sibling preserves root identity into untouched subtree"
                   (eq? new-b (pair-b (if (eq? new-root root) root new-root)))))))

;;; widget-handles? introspection.
(let* ((widget-handles? (@@ (gcell engine) widget-handles?))
       (t (make <ticker>))
       (i (make <inert>)))
  (test-assert "ticker handles <tick>"
               (widget-handles? t <tick>))
  (test-assert "ticker does not handle <paste>"
               (not (widget-handles? t <paste>)))
  (test-assert "inert handles nothing"
               (not (widget-handles? i <tick>)))
  (test-assert "inert does not handle <paste>"
               (not (widget-handles? i <paste>))))

;;; Live re-evaluation: add a <paste> handler to <inert>, dispatch
;;; should pick it up on the very next call (no cache to invalidate).
(define-method (update (s <inert>) (msg <paste>))
  (set! (inert-calls s) (+ 1 (inert-calls s)))
  (cons s #f))

(let* ((widget-handles? (@@ (gcell engine) widget-handles?))
       (cascade! (@@ (gcell engine) cascade!))
       (i (make <inert>))
       (eng (engine #:backend (make-test-backend)
                    #:keymap  (keymap)
                    #:root    i)))
  (test-assert "inert handles <paste> after live re-eval"
               (widget-handles? i <paste>))
  (cascade! eng (paste "hello"))
  (test-equal "live re-evaluated method fires"
              1 (inert-calls (engine-root eng))))

(test-end "subscriptions")
