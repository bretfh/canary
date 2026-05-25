(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (canary node)
             (canary view)
             (canary layout)
             (canary render)
             (canary draw))

(test-begin "node")

;; define-node generates a stateful node with sensible defaults.
(define-node counter
  #:state ((n 0))
  #:view  (lambda (self) (txt (number->string (counter-n self))))
  #:react (lambda (self msg)
            (cond
             ((eq? msg 'inc) (set-counter-n! self (+ 1 (counter-n self))) self)
             ((eq? msg 'dec) (set-counter-n! self (- (counter-n self) 1)) self)
             (else self))))

(test-assert "constructor returns a stateful"
  (stateful? (make-counter)))

(test-assert "predicate identifies counters"
  (counter? (make-counter)))

(test-equal "default state"
  0 (counter-n (make-counter)))

(test-equal "init state via kwarg"
  5 (counter-n (make-counter #:n 5)))

(test-equal "mutate via setter"
  10 (let ((c (make-counter))) (set-counter-n! c 10) (counter-n c)))

;; React mutates state in place.
(let ((c (make-counter #:n 0)))
  ((stateful-react-proc c) c 'inc)
  (test-equal "react inc" 1 (counter-n c))
  ((stateful-react-proc c) c 'inc)
  (test-equal "react inc again" 2 (counter-n c))
  ((stateful-react-proc c) c 'dec)
  (test-equal "react dec" 1 (counter-n c)))

;; Nodes compose in layout primitives without any flattening calls.
(let* ((tree (vbox (txt "header")
                   (make-counter #:n 7)
                   (make-counter #:n 42)))
       (cmds (render tree 20 3))
       (texts (filter-map (lambda (c) (and (text-cmd? c) (text-str c))) cmds)))
  (test-equal "composed lines"
    '("header" "7" "42")
    texts))

;; A node can return new view subtrees by mutating state then re-rendering.
(let ((c (make-counter)))
  (set-counter-n! c 99)
  (let* ((cmds (render c 5 1))
         (txt-cmd (find text-cmd? cmds)))
    (test-equal "post-mutation render" "99" (text-str txt-cmd))))

;; Multi-state node: more than one slot, kwargs work.
(define-node point
  #:state ((x 0) (y 0))
  #:view  (lambda (p)
            (txt (string-append "(" (number->string (point-x p))
                                 "," (number->string (point-y p)) ")"))))

(let ((p (make-point #:x 3 #:y 4)))
  (test-equal "multi-state x" 3 (point-x p))
  (test-equal "multi-state y" 4 (point-y p))
  (set-point-x! p 100)
  (test-equal "multi-state mutate x" 100 (point-x p)))

;; Node without react still composes and renders fine.
(define-node label
  #:state ((text ""))
  #:view (lambda (l) (txt (label-text l))))

(test-equal "no-react node renders"
  "hello"
  (let* ((l (make-label #:text "hello"))
         (cmds (render l 10 1)))
    (text-str (find text-cmd? cmds))))

(test-end "node")
