(define-module (canary backend-test)
  #:use-module (canary backend)
  #:use-module (canary backend-ansi)
  #:use-module (canary draw)
  #:use-module (canary faces)
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
  (faces #:init-keyword #:faces #:accessor test-backend-faces)
  (size #:init-keyword #:size #:init-value '(80 . 24) #:accessor test-backend-size-slot))

(define* (make-test-backend #:key (cols 80) (rows 24) (faces default-faces))
  (make <test-backend> #:size (cons cols rows) #:faces faces))

(define (test-backend-cmds b)
  (reverse (test-backend-cmds-slot b)))

(define (test-backend-clear! b)
  (set! (test-backend-cmds-slot b) '())
  b)

(define (test-backend-size b)
  (test-backend-size-slot b))

(define (test-backend-set-size! b cols rows)
  (set! (test-backend-size-slot b) (cons cols rows))
  b)

(define-method (backend-init (b <test-backend>)) #f)
(define-method (backend-shutdown (b <test-backend>)) #f)
(define-method (backend-size (b <test-backend>)) (test-backend-size-slot b))
(define-method (backend-draw (b <test-backend>) cmds)
  (set! (test-backend-cmds-slot b)
        (append (reverse cmds) (test-backend-cmds-slot b))))

(define (test-backend-grid b)
  (let* ((sz (test-backend-size-slot b))
         (term (t:make-term #:width (car sz) #:height (cdr sz))))
    (render-cmds-to-term! term (test-backend-cmds b) (test-backend-faces b))
    term))

(define (test-backend-dump b)
  (t:term-dump (test-backend-grid b)))

(define (test-backend-row b y)
  (t:term-dump-row (test-backend-grid b) y))

(define (string-contains-substr? hay needle)
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
  (string-contains-substr? (test-backend-dump b) str))

(define (test-backend-find-text b str)
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
