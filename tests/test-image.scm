(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (rnrs bytevectors)
             (gcell)
             (gcell view)
             (gcell draw)
             (gcell render)
             (gcell backend)
             (gcell backend-test))

(test-begin "image")

(test-group "image-node carries declared size"
  (let ((n (image 'foo #:w 4 #:h 2 #:fallback (txt "x"))))
    (test-assert "is an image-node" (image-node? n))
    (test-equal "src" 'foo (image-node-src n))
    (test-equal "w" 4 (image-node-w n))
    (test-equal "h" 2 (image-node-h n))
    (test-equal "view-size" '(4 . 2) (view-size n))))

(test-group "view->cmds emits image-cmd"
  (let* ((n (image 'foo #:w 3 #:h 1 #:fallback (txt "abc")))
         (cmds (render n 10 3)))
    (test-equal "one cmd" 1 (length cmds))
    (test-assert "is image-cmd" (image-cmd? (car cmds)))
    (test-equal "src" 'foo (image-src (car cmds)))
    (test-equal "w" 3 (image-w (car cmds)))))

(test-group "test-backend renders the fallback"
  (let ((b (make-test-backend #:cols 10 #:rows 1)))
    (backend-draw b (render (image 'foo #:w 3 #:h 1
                                   #:fallback (txt "abc"))
                            10 1))
    (test-equal "fallback chars land in grid"
                "abc       " (test-backend-row b 0))))

(test-group "image registry"
  (clear-images!)
  (test-assert "unregistered" (not (image-registered? 'nope)))
  (define-image! 'demo "/etc/hostname")
  (test-assert "registered" (image-registered? 'demo))
  (test-equal "path" "/etc/hostname" (image-path 'demo))
  (let ((bv (image-bytes 'demo)))
    (test-assert "bytes loaded" (and (bytevector? bv) (positive? (bytevector-length bv)))))
  (clear-images!))

(test-group "images batch macro"
  (clear-images!)
  (images (a "/etc/hostname")
          (b "/etc/hostname"))
  (test-assert "a registered" (image-registered? 'a))
  (test-assert "b registered" (image-registered? 'b))
  (clear-images!))

(test-end "image")
