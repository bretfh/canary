(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (gcell view)
             (gcell layout))

(test-begin "view")

(test-equal "text node size" '(5 . 1) (view-size (txt "hello")))
(test-equal "vbox stacks heights"
            '(5 . 3)
            (view-size (vbox (txt "a") (txt "bb") (txt "ccccc"))))
(test-equal "hbox sums widths and maxes heights"
            '(7 . 1)
            (view-size (hbox (txt "ab") (txt "cd") (txt "efg"))))
(test-equal "spacer size" '(0 . 3) (view-size (spacer 3)))

(test-equal "flex is transparent for view-size"
            '(2 . 1)
            (view-size (flex (txt "ab"))))

(test-end "view")
