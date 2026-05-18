(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (canary backend)
             (canary backend-test)
             (canary draw)
             (canary faces)
             (canary view)
             (canary layout)
             (canary borders)
             (canary render))

(test-begin "backend-test")

(test-group "captures cmds in draw order"
  (let ((b (make-test-backend #:cols 20 #:rows 3)))
    (backend-draw b (render (txt "hi") 20 3))
    (test-equal "one cmd captured" 1 (length (test-backend-cmds b)))
    (test-assert "is a text-cmd" (text-cmd? (car (test-backend-cmds b))))))

(test-group "draw appends across calls"
  (let ((b (make-test-backend #:cols 20 #:rows 3)))
    (backend-draw b (render (txt "a") 20 3))
    (backend-draw b (render (txt "b") 20 3))
    (test-equal "two cmds" 2 (length (test-backend-cmds b)))))

(test-group "clear resets cmds"
  (let ((b (make-test-backend #:cols 20 #:rows 3)))
    (backend-draw b (render (txt "x") 20 3))
    (test-backend-clear! b)
    (test-equal "empty after clear" 0 (length (test-backend-cmds b)))))

(test-group "grid reflects the view"
  (let ((b (make-test-backend #:cols 12 #:rows 3)))
    (backend-draw b (render (vbox (txt "alpha") (txt "beta")) 12 3))
    (test-equal "row 0" "alpha       " (test-backend-row b 0))
    (test-equal "row 1" "beta        " (test-backend-row b 1))
    (test-equal "row 2 blank" "            " (test-backend-row b 2))))

(test-group "text? finds substrings in the rendered grid"
  (let ((b (make-test-backend #:cols 30 #:rows 5)))
    (backend-draw b (render (vbox (txt "hello world") (boxed (txt "x"))) 30 5))
    (test-assert "finds hello" (test-backend-text? b "hello"))
    (test-assert "finds boxed glyph" (test-backend-text? b "┌─┐"))
    (test-assert "absent string returns #f" (not (test-backend-text? b "nothing")))))

(test-group "find-text returns (col . row)"
  (let ((b (make-test-backend #:cols 30 #:rows 5)))
    (backend-draw b (render (vbox (txt "first") (txt "  second")) 30 5))
    (test-equal "first at 0,0" '(0 . 0) (test-backend-find-text b "first"))
    (test-equal "second at 2,1" '(2 . 1) (test-backend-find-text b "second"))
    (test-equal "missing returns #f" #f (test-backend-find-text b "third"))))

(test-group "size accessor and setter"
  (let ((b (make-test-backend #:cols 10 #:rows 5)))
    (test-equal "initial size" '(10 . 5) (test-backend-size b))
    (test-backend-set-size! b 40 12)
    (test-equal "after resize" '(40 . 12) (test-backend-size b))))

(test-end "backend-test")
