(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (canary view)
             (canary layout)
             (canary render)
             (canary draw))

(test-begin "hover")

;; The hover-node renders its body normally; when the cursor (threaded
;; through *mouse-x* / *mouse-y* parameters by render) is inside the
;; node's assigned rect, it renders the styler's output instead.

(define normal  (txt "off"))
(define hovered (txt "on"))
(define hov     (on-hover normal (lambda (_) hovered)))

(define (text-of cmds)
  (let ((tc (find text-cmd? cmds)))
    (and tc (text-str tc))))

;; Cursor far away → body shown
(test-equal "cursor outside → body renders"
  "off" (text-of (render hov 10 1 #:mouse-x 100 #:mouse-y 100)))

;; Cursor on the node → styler output renders
(test-equal "cursor inside → styler output renders"
  "on"  (text-of (render hov 10 1 #:mouse-x 1 #:mouse-y 0)))

;; Cursor at default (-1, -1) → body
(test-equal "no cursor → body renders"
  "off" (text-of (render hov 10 1)))

;; Nested hover composes: cursor inside both outer and inner rects
;; fires both layers — outer swaps to its styler output (inner), inner
;; sees the cursor in its own rect and swaps to its hover form.
(let* ((inner   (on-hover (txt "i-off") (lambda (_) (txt "i-on"))))
       (wrapped (vbox (on-hover (txt "outer") (lambda (_) inner)))))
  (test-equal "nested hover composes — both layers fire"
    "i-on"
    (text-of (render wrapped 10 1 #:mouse-x 1 #:mouse-y 0))))

;; Click-region emission survives hover wrapping
(let* ((tree (on-click (on-hover (txt "btn") (lambda (_) (txt "BTN")))
                       #:action 'fire))
       (cmds (render tree 10 1 #:mouse-x 100 #:mouse-y 100))
       (click (find clickable-cmd? cmds)))
  (test-assert "click-region emitted even when not hovered"
    (and click (eq? (clickable-action click) 'fire))))

(test-end "hover")
