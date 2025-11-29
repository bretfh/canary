#!/usr/bin/env guile
!#

(add-to-load-path (dirname (dirname (current-filename))))
(add-to-load-path "/opt/homebrew/share/guile/site/3.0")

(use-modules (tuition terminal)
             (tuition style)
             (tuition protocol)
             (tuition app)
             (tuition layout)
             (tuition borders)
             (tuition table)
             (tuition components progress)
             (tuition components spinner)
             (ice-9 match)
             (oop goops))

;;; Model
(define-class <model> ()
  (count #:init-value 0 #:accessor count)
  (spinner #:init-value #f #:accessor spinner-val))

;;; Messages
(define-class <tick> ())

;;; Init
(define (init m)
  (set! (spinner-val m) (make-spinner #:frames spinner-dots))
  (lambda ()
    (sleep 0.1)
    (make <tick>)))

;;; Update
(define (update m msg)
  (cond
   ((is-a? msg <tick>)
    (spinner-tick! (spinner-val m))
    (set! (count m) (modulo (+ (count m) 1) 101))
    (values m (lambda () (sleep 0.1) (make <tick>))))

   ((is-a? msg <key-msg>)
    (case (key msg)
      ((#\q) (values m (quit-cmd)))
      ((#\+) (set! (count m) (+ (count m) 5)) (values m #f))
      ((#\-) (set! (count m) (max 0 (- (count m) 5))) (values m #f))
      (else (values m #f))))

   (else (values m #f))))

;;; View
(define (view m)
  (vbox
   (boxed "guile-tuition components test" #:border border-double #:fg 4)
   (spacer 1)

   (txt "Borders:" #:bold? #t)
   (spacer 1)
   (hbox (boxed "Normal" #:border border-normal)
         " "
         (boxed "Rounded" #:border border-rounded)
         " "
         (boxed "Thick" #:border border-thick))
   (spacer 2)

   (txt "Progress:" #:bold? #t)
   (spacer 1)
   (progress-render (make-progress #:current (count m) #:total 100))
   (spacer 2)

   (txt "Spinner:" #:bold? #t)
   (spacer 1)
   (hbox (spinner-render (spinner-val m)) " Loading...")
   (spacer 2)

   (txt "Table:" #:bold? #t)
   (spacer 1)
   (let ((tbl (make-table #:headers '("Item" "Value") #:border border-rounded)))
     (table-add-row tbl (list "Count" (number->string (count m))))
     (table-add-row tbl (list "Status" (fg "Active" 2)))
     (table-render tbl))
   (spacer 2)

   (txt "+/- adjust | q quit" #:fg 8)))

;;; Run
(define model (make <model>))
(define app (make-app model (current-module)))
(run-app app)
