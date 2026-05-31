(define-module (gcell components paginator)
  #:use-module (gcell view)
  #:use-module (gcell layout)
  #:use-module (gcell protocol)
  #:use-module (gcell key)
  #:use-module (gcell widget)
  #:use-module (ice-9 match)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<paginator>
            paginator?
            paginator
            paginator-type
            paginator-page
            paginator-per-page
            paginator-total-pages
            paginator-prev-page
            paginator-next-page
            paginator-on-first-page?
            paginator-on-last-page?
            paginator-get-slice-bounds))

(define-class <paginator> (<focusable>)
  (type          #:init-keyword #:type          #:init-value 'arabic
                 #:getter paginator-type)
  (page          #:init-keyword #:page          #:init-value 0
                 #:getter paginator-page)
  (per-page      #:init-keyword #:per-page      #:init-value 10
                 #:getter paginator-per-page)
  (total-pages   #:init-keyword #:total-pages   #:init-value 1
                 #:getter paginator-total-pages)
  (active-dot    #:init-keyword #:active-dot    #:init-value "•"
                 #:getter paginator-active-dot)
  (inactive-dot  #:init-keyword #:inactive-dot  #:init-value "○"
                 #:getter paginator-inactive-dot)
  (arabic-format #:init-keyword #:arabic-format #:init-value "~d/~d"
                 #:getter paginator-arabic-format))

(define (paginator? x)
  "Return #t if X is a <paginator>."
  (is-a? x <paginator>))

(define (paginator . args)
  "Return a fresh <paginator> initialised from ARGS, a sequence of
#:type, #:page, #:per-page, #:total-pages, #:active-dot,
#:inactive-dot, #:arabic-format keyword arguments."
  (apply make <paginator> args))

(define (paginator-prev-page p)
  "Return P with its page index decremented, clamped at 0."
  (cond
   ((zero? (paginator-page p)) p)
   (else (update-slots p #:page (- (paginator-page p) 1)))))

(define (paginator-next-page p)
  "Return P with its page index incremented, clamped at total-pages -
1."
  (cond
   ((>= (paginator-page p) (- (paginator-total-pages p) 1)) p)
   (else (update-slots p #:page (+ (paginator-page p) 1)))))

(define (paginator-on-first-page? p)
  "Return #t if P is positioned on the first page."
  (= (paginator-page p) 0))

(define (paginator-on-last-page? p)
  "Return #t if P is positioned on the last page."
  (= (paginator-page p) (- (paginator-total-pages p) 1)))

(define (paginator-get-slice-bounds p length)
  "Return two values: the [start, end) item indices that P's current
page maps to within a sequence of LENGTH items.  Clamps so end never
exceeds LENGTH; returns (0, 0) if LENGTH is zero."
  (if (zero? length)
      (values 0 0)
      (let* ((page     (paginator-page p))
             (per-page (paginator-per-page p))
             (start    (min (* page per-page) length))
             (end      (min (+ start per-page) length)))
        (values start end))))

(define (paginator-dots-view p)
  "Render P as a row of dots, one per page, with the active page's
dot in accent face and the rest in muted."
  (apply hbox
         (map (lambda (i)
                (if (= i (paginator-page p))
                    (txt (paginator-active-dot p) #:fg 'accent)
                    (txt (paginator-inactive-dot p) #:fg 'muted)))
              (iota (paginator-total-pages p)))))

(define (paginator-arabic-view p)
  "Render P as \"N/M\" text in muted face."
  (txt (format #f "~d/~d" (+ 1 (paginator-page p)) (paginator-total-pages p))
       #:fg 'muted))

(define-method (view (p <paginator>))
  "Render <paginator> P, dispatching on P's type slot ('dots or
'arabic, defaulting to arabic)."
  (case (paginator-type p)
    ((dots) (paginator-dots-view p))
    (else   (paginator-arabic-view p))))

(define-method (update (p <paginator>) (msg <key>))
  "Right / page-down / `l` advances the page; left / page-up / `h`
retreats.  Other keys leave P unchanged."
  (cons
   (match (key-sym msg)
     ((or 'right 'page-down) (paginator-next-page p))
     ((or 'left  'page-up)   (paginator-prev-page p))
     ((? (lambda (c) (and (char? c) (char=? c #\l)))) (paginator-next-page p))
     ((? (lambda (c) (and (char? c) (char=? c #\h)))) (paginator-prev-page p))
     (_ p))
   #f))
