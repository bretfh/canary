#!/usr/bin/env guile
!#

(add-to-load-path (dirname (dirname (current-filename))))
(add-to-load-path "/opt/homebrew/share/guile/site/3.0")

(use-modules (tuition terminal)
             (tuition style)
             (tuition protocol)
             (tuition app)
             (tuition layout)
             (tuition sexp-buffer)
             (system repl server)
             (ice-9 threads)
             (ice-9 match)
             (oop goops)
             (srfi srfi-1))

;; Spawn REPL server
(call-with-new-thread
 (lambda ()
   (catch #t
     (lambda () (spawn-server))
     (lambda (key . args) #f))))

;;; Model
(define-class <editor-model> ()
  (buffer #:init-keyword #:buffer #:accessor buffer))

;;; Init
(define (init m)
  #f)

;;; Update
(define (update m msg)
  (cond
   ;; Key messages
   ((is-a? msg <key-msg>)
    (let ((k (key msg))
          (buf (buffer m)))
      (case k
        ;; Quit
        ((#\q) (values m (quit-cmd)))

        ;; Navigation - hjkl spatial
        ((#\h) (up-list buf) (values m #f))        ; left - out of list
        ((#\l) (down-list buf) (values m #f))      ; right - into list
        ((#\j) (forward-sexp buf) (values m #f))   ; down - next sibling
        ((#\k) (backward-sexp buf) (values m #f))  ; up - prev sibling

        ;; Insert sexp (TODO: fix for path-based cursor)
        ;; ((#\i)
        ;;  (insert-sexp buf 'new-symbol)
        ;;  (values m #f))

        ;; Delete sexp (TODO: fix for path-based cursor)
        ;; ((#\d)
        ;;  (delete-sexp buf)
        ;;  (values m #f))

        (else (values m #f)))))

   (else (values m #f))))

;;; View helpers
(define (render-sexp sexp is-current?)
  "Render a single sexp"
  (let ((lines (string-split (format-sexp sexp) #\newline)))
    (apply vbox
           (map (lambda (line)
                  (if is-current?
                      (txt line #:bold? #t #:fg 2)
                      (txt line #:fg 7)))
                lines))))

;;; View
(define (view m)
  (let* ((buf (buffer m))
         (sexps (content buf))
         (cursor-path (cursor buf))
         (current (current-sexp buf)))
    (vbox
     (txt "SEXP EDITOR" #:bold? #t #:fg 5)
     (txt "───────────" #:fg 5)
     (hbox "Path: " (txt (object->string cursor-path) #:fg 3)
           "  |  At: " (txt (object->string current) #:fg 6))
     (spacer 1)

     ;; Show all sexps with cursor highlighted
     (if (null? sexps)
         (txt "  (empty buffer)" #:fg 8)
         (let ((lines (render-buffer-with-cursor sexps cursor-path)))
           (apply vbox
                  (map (lambda (pair)
                         (match pair
                           ((text . #t) (txt text #:fg 0 #:bg 2))
                           ((text . #f) (txt text #:fg 7))))
                       lines))))

     (spacer 1)
     (txt "Controls:" #:fg 8)
     (txt "  h/l - out/into list    j/k - next/prev sexp" #:fg 7)
     (txt "  q - quit" #:fg 7)
     (spacer 1)
     (txt "Geiser: M-x geiser-connect RET localhost RET 37146" #:fg 8)
     (spacer 1)
     (error-console app))))

;;; Run
(define sample-sexps
  '((define (factorial n)
      (if (<= n 1)
          1
          (* n (factorial (- n 1)))))
    (define (fibonacci n)
      (cond
       ((= n 0) 0)
       ((= n 1) 1)
       (else (+ (fibonacci (- n 1))
                (fibonacci (- n 2))))))
    (+ 1 2 3)))

(define buf (make <sexp-buffer> #:content sample-sexps #:cursor '(0)))
(define initial-model (make <editor-model> #:buffer buf))
(define app (make-app initial-model (current-module)))
(run-app app)
