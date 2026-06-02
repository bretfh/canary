(define-module (canary borders)
  #:use-module (canary view)
  #:use-module (canary faces)
  #:use-module (srfi srfi-9)
  #:export (<border>
            border?
            border
            border-top
            border-bottom
            border-left
            border-right
            border-tl
            border-tr
            border-bl
            border-br
            border-normal
            border-rounded
            border-thick
            border-double
            border-ascii
            boxed))

(define-record-type <border>
  (border top bottom left right tl tr bl br)
  border?
  (top border-top)
  (bottom border-bottom)
  (left border-left)
  (right border-right)
  (tl border-tl)
  (tr border-tr)
  (bl border-bl)
  (br border-br))

(define border-normal
  (border "─" "─" "│" "│" "┌" "┐" "└" "┘"))

(define border-rounded
  (border "─" "─" "│" "│" "╭" "╮" "╰" "╯"))

(define border-thick
  (border "━" "━" "┃" "┃" "┏" "┓" "┗" "┛"))

(define border-double
  (border "═" "═" "║" "║" "╔" "╗" "╚" "╝"))

(define border-ascii
  (border "-" "-" "|" "|" "+" "+" "+" "+"))

(define* (boxed body #:key (border border-normal) (fg #f) (bg #f)
                (title #f))
  "TITLE, if non-#f, is spliced into the top border as ┤ TITLE ├ near
the left corner. Renders as standard boxed when TITLE is #f."
  (let ((f (if (or fg bg) (face #:fg fg #:bg bg #:attrs '()) #f)))
    (make-boxed-node body border f title)))
