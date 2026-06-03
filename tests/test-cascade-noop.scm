(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (canary view)
             (canary layout)
             (canary widget)
             (canary protocol)
             (canary keymap)
             ((canary engine-types) #:select (engine))
             ((canary backend-test) #:select (make-test-backend))
             (oop goops))

(test-begin "cascade-noop")

(define-component <noop>
  (n #:init-keyword #:n #:init-value 0 #:getter noop-n))

(define-method (view (w <noop>)) (txt "noop"))

;; No update method specialised on this class: every msg falls through
;; to the default at view.scm:562 which returns nothing, so the engine
;; reuses the same node.  Exercises the (eq? new-node node) gate in
;; dispatch-update!.

(let* ((dispatch-update! (@@ (canary engine) dispatch-update!))
       (w   (make <noop>))
       (cache (make-hash-table))
       (eng (engine #:backend (make-test-backend)
                    #:keymap  (keymap)
                    #:root    w)))
  (with-view-cache cache
    (lambda ()
      (memoized-view w)
      (test-assert "view cache populated by memoized-view"
                   (hash-ref cache w))
      (let ((result (dispatch-update! eng w (tick))))
        (test-assert "no-op cascade returns same identity"
                     (eq? w (car result))))
      (test-assert "view cache preserved across no-op cascade"
                   (hash-ref cache w)))))

;; State-changing cascade: update-slots breaks identity, so the gate
;; opens; the cascade returns a fresh instance.
(define-component <bump>
  (n #:init-keyword #:n #:init-value 0 #:getter bump-n))

(define-method (view (w <bump>)) (txt "bump"))

(define-method (update (w <bump>) (msg <tick>))
  (cons (update-slots w #:n (+ 1 (bump-n w))) #f))

(let* ((dispatch-update! (@@ (canary engine) dispatch-update!))
       (w   (make <bump>))
       (eng (engine #:backend (make-test-backend)
                    #:keymap  (keymap)
                    #:root    w)))
  (let* ((result (dispatch-update! eng w (tick)))
         (new-w  (car result)))
    (test-assert "stateful cascade returns a fresh instance"
                 (not (eq? w new-w)))
    (test-equal "fresh instance carries the bumped slot value"
                1 (bump-n new-w))))

(test-end "cascade-noop")
