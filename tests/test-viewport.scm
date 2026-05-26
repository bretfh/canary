(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (canary view)
             (canary layout)
             (canary components viewport)
             (oop goops))

(test-begin "viewport")

(define (text-lines->items strs) (map (lambda (s) (txt s)) strs))

(define (vbox-children node)
  "Pull the children list out of a <vbox-node>, or '() if NODE is the
empty-string placeholder."
  (cond
   ((vbox-node? node) (vbox-node-items node))
   (else '())))

(define ten (text-lines->items
             '("a" "b" "c" "d" "e" "f" "g" "h" "i" "j")))

(test-group "no height returns all items from offset (top mode)"
  (let* ((v (viewport #:items ten #:offset 3))
         (out (view v)))
    (test-equal "7 items shown" 7 (length (vbox-children out)))))

(test-group "height clamps the window (top mode)"
  (let* ((v (viewport #:items ten #:offset 2 #:height 3))
         (out (view v)))
    (test-equal "3 items shown" 3 (length (vbox-children out)))))

(test-group "height larger than remaining doesn't overrun"
  (let* ((v (viewport #:items ten #:offset 8 #:height 10))
         (out (view v)))
    (test-equal "2 items shown" 2 (length (vbox-children out)))))

(test-group "bottom mode windows the tail"
  (let* ((v (viewport #:items ten #:offset 0 #:from 'bottom #:height 4))
         (out (view v)))
    (test-equal "4 items shown" 4 (length (vbox-children out)))))

(test-group "bottom mode honours offset (skip from end) plus height"
  (let* ((v (viewport #:items ten #:offset 2 #:from 'bottom #:height 3))
         (out (view v)))
    (test-equal "3 items shown" 3 (length (vbox-children out)))))

(test-group "huge list with small height stays O(window)"
  (let* ((big (text-lines->items
               (map number->string (iota 100000))))
         (v (viewport #:items big #:offset 50000 #:height 30))
         (out (view v)))
    (test-equal "30 items shown" 30 (length (vbox-children out)))))

(test-end "viewport")
