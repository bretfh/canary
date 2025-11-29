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
             (oop goops))

;;; Model
(define-class <model> ()
  (n #:init-value 0 #:accessor n))

;;; Init
(define (init m)
  #f)

;;; Update
(define (update m msg)
  (cond
   ((is-a? msg <key-msg>)
    (case (key msg)
      ((#\q) (values m (quit-cmd)))
      (else (values m #f))))
   (else (values m #f))))

;;; View
(define (view m)
  (vbox
   (boxed "IT WORKS!" #:border border-double #:fg "#00ff00")
   (spacer 1)
   (txt "Press q to quit" #:fg "#888")
   (spacer 2)
   (error-console app)))

;;; Run
(define model (make <model>))
(define app (make-app model (current-module)))
(run-app app)
