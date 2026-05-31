(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (fibers channels)
             (gcell engine)
             (gcell engine-types)
             (gcell backend-ansi)
             (gcell protocol)
             (gcell layout)
             (oop goops))

(test-begin "resize-debounce")

(test-assert "resize-flushed? recognises wrapped resize"
             (resize-flushed? (cons 'resize-flushed (resize 80 24))))

(test-assert "resize-flushed? rejects bare resize"
             (not (resize-flushed? (resize 80 24))))

(test-assert "resize-flushed? rejects wrong tag"
             (not (resize-flushed? (cons 'other (resize 80 24)))))

(test-group "handle-resize! caches new dims on backend"
  (let* ((b   (ansi-backend #:port (open-output-string)))
         (eng (engine #:backend b #:root (txt "hi")
                           #:msg-bell       (cons (open-input-string "") (open-output-string))
                           #:stop-ch        (cons (open-input-string "") (open-output-string))
                           #:resize-channel (make-channel))))
    (set! (ansi-backend-size b) (size 80 24))
    (handle-resize! eng (resize 132 50))
    (test-equal "width updated" 132 (size-width  (ansi-backend-size b)))
    (test-equal "height updated" 50 (size-height (ansi-backend-size b)))
    (test-assert "prev-term invalidated for full repaint"
                 (not (ansi-backend-prev-term b)))))

(test-end "resize-debounce")
