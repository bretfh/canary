(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (fibers channels)
             (gcell engine)
             (gcell engine-types)
             (gcell widget)
             (gcell backend-ansi)
             (gcell protocol)
             (gcell view)
             (gcell layout)
             (oop goops))

(test-begin "lifecycle")

(define-class <tape> (<focusable>)
  (msgs #:init-value '() #:accessor tape-msgs))

(define-method (view (t <tape>)) (txt "x"))

(define-method (update (t <tape>) msg)
  (set! (tape-msgs t) (cons msg (tape-msgs t)))
  #f)

(define (received-mount? t)
  (any mount? (tape-msgs t)))

(define (received-unmount? t)
  (any unmount? (tape-msgs t)))

(define (make-test-engine root)
  (let ((b (ansi-backend #:port (open-output-string))))
    (set! (ansi-backend-size b) (size 20 10))
    (engine #:backend b #:root root
                 #:msg-bell       (cons (open-input-string "") (open-output-string))
                 #:stop-ch        (cons (open-input-string "") (open-output-string))
                 #:resize-channel (make-channel))))

(test-group "mount fires when widget first seen"
  (let* ((t   (make <tape>))
         (eng (make-test-engine t)))
    (refresh-live-widgets! eng)
    (test-assert "tape got <mount>" (received-mount? t))
    (test-assert "tape did not get <unmount>" (not (received-unmount? t)))))

(test-group "mount is idempotent across frames"
  (let* ((t   (make <tape>))
         (eng (make-test-engine t)))
    (refresh-live-widgets! eng)
    (set! (tape-msgs t) '())   ; reset
    (refresh-live-widgets! eng)
    (test-assert "no second <mount>" (not (received-mount? t)))))

(test-group "unmount fires when widget removed from tree"
  (let* ((kept    (make <tape>))
         (dropped (make <tape>))
         (eng     (make-test-engine (vbox kept dropped))))
    (refresh-live-widgets! eng)
    (test-assert "dropped got <mount>" (received-mount? dropped))
    ;; Swap to a tree without `dropped'.
    (set-engine-root! eng (vbox kept))
    (set! (tape-msgs dropped) '())
    (refresh-live-widgets! eng)
    (test-assert "dropped got <unmount>" (received-unmount? dropped))))

(test-group "sub installed during update is auto-cancelled on unmount"
  (let* ((sub-id 'ticker-X)
         (drop   (make <tape>))
         (eng    (make-test-engine drop)))
    (refresh-live-widgets! eng)
    ;; Simulate the widget installing a tagged sub during its update.
    ;; install-sub! reads current-update-widget; cascading <mount>
    ;; through dispatch-update! sets that for us, so do the same here
    ;; by faking a sub directly in engine-subs and engine-widget-subs.
    (hash-set! (engine-subs eng)        sub-id            (list #f))
    (hash-set! (engine-widget-subs eng) (widget-id drop)  (list sub-id))
    (test-assert "sub is installed" (hash-ref (engine-subs eng) sub-id))
    ;; Remove the widget — unmount should cancel.
    (set-engine-root! eng (txt "empty"))
    (refresh-live-widgets! eng)
    (test-assert "sub auto-cancelled on unmount"
                 (not (hash-ref (engine-subs eng) sub-id)))
    (test-assert "widget-subs entry removed"
                 (not (hash-ref (engine-widget-subs eng) (widget-id drop))))))

(test-end "lifecycle")
