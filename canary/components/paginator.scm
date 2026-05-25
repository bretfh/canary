(define-module (canary components paginator)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary protocol)
  #:use-module (canary key)
  #:use-module (ice-9 match)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<paginator>
            paginator?
            make-paginator
            paginator-type
            paginator-page
            paginator-per-page
            paginator-total-pages
            paginator-prev-page!
            paginator-next-page!
            paginator-on-first-page?
            paginator-on-last-page?
            paginator-get-slice-bounds))

(define-class <paginator> ()
  (type          #:init-keyword #:type          #:init-value 'arabic
                 #:accessor paginator-type)
  (page          #:init-keyword #:page          #:init-value 0
                 #:accessor paginator-page)
  (per-page      #:init-keyword #:per-page      #:init-value 10
                 #:accessor paginator-per-page)
  (total-pages   #:init-keyword #:total-pages   #:init-value 1
                 #:accessor paginator-total-pages)
  (active-dot    #:init-keyword #:active-dot    #:init-value "•"
                 #:accessor paginator-active-dot)
  (inactive-dot  #:init-keyword #:inactive-dot  #:init-value "○"
                 #:accessor paginator-inactive-dot)
  (arabic-format #:init-keyword #:arabic-format #:init-value "~d/~d"
                 #:accessor paginator-arabic-format))

(define (paginator? x) (is-a? x <paginator>))
(define (make-paginator . args) (apply make <paginator> args))

(define (paginator-prev-page! p)
  (when (> (paginator-page p) 0)
    (set! (paginator-page p) (- (paginator-page p) 1)))
  p)

(define (paginator-next-page! p)
  (when (< (paginator-page p) (- (paginator-total-pages p) 1))
    (set! (paginator-page p) (+ (paginator-page p) 1)))
  p)

(define (paginator-on-first-page? p) (= (paginator-page p) 0))
(define (paginator-on-last-page? p)
  (= (paginator-page p) (- (paginator-total-pages p) 1)))

(define (paginator-get-slice-bounds p length)
  (if (zero? length)
      (values 0 0)
      (let* ((page     (paginator-page p))
             (per-page (paginator-per-page p))
             (start    (min (* page per-page) length))
             (end      (min (+ start per-page) length)))
        (values start end))))

(define (paginator-dots-view p)
  (apply hbox
         (map (lambda (i)
                (if (= i (paginator-page p))
                    (txt (paginator-active-dot p) #:fg 'accent)
                    (txt (paginator-inactive-dot p) #:fg 'muted)))
              (iota (paginator-total-pages p)))))

(define (paginator-arabic-view p)
  (txt (format #f "~d/~d" (+ 1 (paginator-page p)) (paginator-total-pages p))
       #:fg 'muted))

(define-method (view (p <paginator>) sz)
  (case (paginator-type p)
    ((dots) (paginator-dots-view p))
    (else   (paginator-arabic-view p))))

(define-method (update (p <paginator>) msg sz)
  (when (key? msg)
    (let ((k (key-sym msg)))
      (match k
        ((or 'right 'page-down) (paginator-next-page! p))
        ((or 'left  'page-up)   (paginator-prev-page! p))
        ((? (lambda (c) (and (char? c) (char=? c #\l)))) (paginator-next-page! p))
        ((? (lambda (c) (and (char? c) (char=? c #\h)))) (paginator-prev-page! p))
        (_ #f))))
  (values p #f))
