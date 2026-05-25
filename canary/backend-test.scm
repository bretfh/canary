(define-module (canary backend-test)
  #:use-module (canary backend)
  #:use-module (canary backend-ansi)
  #:use-module (canary draw)
  #:use-module (canary theme)
  #:use-module (canary protocol)
  #:use-module ((canary term types) #:prefix t:)
  #:use-module ((canary term render) #:prefix t:)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<test-backend>
            make-test-backend
            test-backend-cmds
            test-backend-clear!
            test-backend-size
            test-backend-set-size!
            test-backend-grid
            test-backend-row
            test-backend-dump
            test-backend-text?
            test-backend-find-text))

(define-class <test-backend> (<backend>)
  (cmds #:init-value '() #:accessor test-backend-cmds-slot)
  (theme #:init-keyword #:theme #:accessor test-backend-theme)
  (size #:init-keyword #:size #:init-value (size 80 24) #:accessor test-backend-size-slot))

(define* (make-test-backend #:key (cols 80) (rows 24) (theme default-theme))
  "Return a fresh <test-backend> sized COLS by ROWS with theme THEME.
Defaults to 80x24 / default-theme."
  (make <test-backend> #:size (size cols rows) #:theme theme))

(define (test-backend-cmds b)
  "Return the draw cmds B has recorded, in the order they were
issued (oldest first)."
  (reverse (test-backend-cmds-slot b)))

(define (test-backend-clear! b)
  "Drop B's recorded draw cmds.  Returns B."
  (set! (test-backend-cmds-slot b) '())
  b)

(define (test-backend-size b)
  "Return the current <size> of test backend B."
  (test-backend-size-slot b))

(define (test-backend-set-size! b cols rows)
  "Resize B to COLS by ROWS, simulating a SIGWINCH for tests.
Returns B."
  (set! (test-backend-size-slot b) (size cols rows))
  b)

(define-method (backend-init (b <test-backend>)) #f)
(define-method (backend-shutdown (b <test-backend>)) #f)
(define-method (backend-size (b <test-backend>)) (test-backend-size-slot b))
(define-method (backend-draw (b <test-backend>) cmds)
  (set! (test-backend-cmds-slot b)
        (append (reverse cmds) (test-backend-cmds-slot b))))

(define (test-backend-grid b)
  "Replay B's recorded cmds onto a fresh term grid and return it.
Used to materialise the would-be screen for assertions."
  (let* ((sz (test-backend-size-slot b))
         (term (t:make-term #:width (size-width sz) #:height (size-height sz))))
    (render-cmds-to-term! term (test-backend-cmds b) (test-backend-theme b))
    term))

(define (test-backend-dump b)
  "Return B's grid as a single string with rows separated by newlines."
  (t:term-dump (test-backend-grid b)))

(define (test-backend-row b y)
  "Return row Y of B's grid as a string."
  (t:term-dump-row (test-backend-grid b) y))

(define (string-contains-substr? hay needle)
  "Return #t if NEEDLE appears anywhere in HAY.  The empty string is
contained in every string."
  (let ((hn (string-length hay))
        (nn (string-length needle)))
    (cond
     ((zero? nn) #t)
     ((> nn hn) #f)
     (else
      (let lp ((i 0))
        (cond
         ((> (+ i nn) hn) #f)
         ((string=? (substring hay i (+ i nn)) needle) #t)
         (else (lp (+ i 1)))))))))

(define (test-backend-text? b str)
  "Return #t if STR appears anywhere in B's rendered output."
  (string-contains-substr? (test-backend-dump b) str))

(define (test-backend-find-text b str)
  "Return a cons (X . Y) for the first row-major occurrence of STR in
B's rendered output, or #f if STR is absent."
  (let* ((dump (test-backend-dump b))
         (lines (string-split dump #\newline)))
    (let lp ((rows lines) (y 0))
      (cond
       ((null? rows) #f)
       (else
        (let ((row (car rows)))
          (let scan ((x 0))
            (cond
             ((> (+ x (string-length str)) (string-length row)) (lp (cdr rows) (+ y 1)))
             ((string=? (substring row x (+ x (string-length str))) str)
              (cons x y))
             (else (scan (+ x 1)))))))))))
