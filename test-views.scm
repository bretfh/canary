#!/usr/bin/env guile
!#

(add-to-load-path (dirname (current-filename)))
(add-to-load-path "/opt/homebrew/share/guile/site/3.0")

(use-modules (tuition style)
             (tuition text)
             (tuition layout)
             (tuition borders)
             (tuition table)
             (tuition components progress)
             (tuition components spinner)
             (tuition components textinput)
             (oop goops))

(format #t "Testing components...~%~%")

(format #t "1. Border test:~%")
(display (boxed "Test" #:border border-rounded #:fg 2))
(newline)(newline)

(format #t "2. Table test:~%")
(let ((tbl (make-table #:headers '("Name" "Value") #:border border-rounded)))
  (table-add-row tbl '("Foo" "Bar"))
  (table-add-row tbl (list "Color" (fg "Green" 2)))
  (display (table-render tbl)))
(newline)(newline)

(format #t "3. Progress test:~%")
(display (progress-render (make-progress #:current 50 #:total 100)))
(newline)(newline)

(format #t "4. Spinner test:~%")
(display (spinner-render (make-spinner)))
(newline)(newline)

(format #t "5. Textinput test:~%")
(display (textinput-view (make-textinput #:placeholder "Type here")))
(newline)(newline)

(format #t "6. Complex vbox test:~%")
(display (vbox
          (boxed "Title" #:border border-double #:fg 4)
          (spacer 1)
          (txt "Some text" #:bold? #t)
          (spacer 1)
          (progress-render (make-progress #:current 75 #:total 100))))
(newline)(newline)

(format #t "All tests completed successfully!~%")
