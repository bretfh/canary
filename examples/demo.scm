#!/usr/bin/env guile
!#

(add-to-load-path (dirname (dirname (current-filename))))
(add-to-load-path "/opt/homebrew/share/guile/site/3.0")

(use-modules (tuition terminal)
             (tuition style)
             (tuition protocol)
             (tuition app)
             (tuition layout)
             (system repl server)
             (ice-9 threads)
             (oop goops))

;; Spawn REPL server in background thread
(call-with-new-thread
 (lambda ()
   (catch #t
     (lambda () (spawn-server))
     (lambda (key . args)
       (format (current-error-port) "REPL server failed: ~a ~a~%" key args)))))

;;; Model
(define-class <counter-model> ()
  (count #:init-keyword #:count #:init-value 0 #:accessor count)
  (text #:init-keyword #:text #:init-value "" #:accessor text))

;;; Init - no initial command
(define (init model)
  #f)

;;; Update - handle messages
(define (update model msg)
  (cond
   ;; Key messages
   ((is-a? msg <key-msg>)
    (let ((k (key msg)))
      (case k
        ;; Quit on q
        ((#\q #\Q)
         (values model (quit-cmd)))

        ;; Increment on +
        ((#\+)
         (set! (count model) (+ (count model) 1))
         (values model #f))

        ;; Decrement on -
        ((#\-)
         (set! (count model) (- (count model) 1))
         (values model #f))

        ;; Reset on r
        ((#\r #\R)
         (set! (count model) 0)
         (values model #f))

        ;; Default - no change
        (else (values model #f)))))

   ;; Window size messages
   ((is-a? msg <window-size-msg>)
    (values model #f))

   ;; Default
   (else (values model #f))))

;;; View - render the model
(define (view model)
  (vbox (txt "Counter Demo" #:bold? #t #:fg 2)
        (spacer 1)
        (hbox "Count: " (txt (number->string (count model)) #:bold? #t))
        (hbox "Text:  " (txt (text model) #:italic? #t))
        (spacer 1)
        (txt "Controls:" #:fg 8)
        (txt "+    Increment")
        (txt "-    Decrement")
        (txt "r    Reset")
        (txt "q    Quit")
        (spacer 1)
        (txt "Geiser: M-x geiser-connect RET localhost RET 37146" #:fg 8)
        (spacer 1)
        (error-console app)))

;;; Create and run app
(define model (make <counter-model> #:count 0 #:text "Hello from TEA!"))
(define app (make-app model (current-module)))
(run-app app)

;; From Geiser: M-x geiser-connect RET localhost RET 37146
;; Live code - just redefine functions and mutate model:
;;
;; Mutate model fields (appears instantly):
;;   (set! (count model) 100)
;;   (set! (text model) "Changed live!")
;;
;; Redefine view with layout DSL (appears instantly):
;;   (define (view model)
;;     (vbox
;;       (txt "LIVE CODING!" #:bold? #t #:fg 1)
;;       (spacer 1)
;;       (hbox "Count: " (txt (number->string (count model)) #:bold? #t))))
;;
;; Redefine update to change behavior:
;;   (define (update model msg)
;;     (cond
;;       ((is-a? msg <key-msg>)
;;        (case (key msg)
;;          ((#\x) (values model (quit-cmd)))
;;          (else (values model #f))))
;;       (else (values model #f))))

