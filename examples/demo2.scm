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
             (oop goops)
             (srfi srfi-19)
             (fibers)
             (fibers channels))

;; Spawn REPL server
(call-with-new-thread
 (lambda ()
   (catch #t
     (lambda () (spawn-server))
     (lambda (key . args) #f))))

;;; Custom message types
(define-class <tick-msg> ()
  (time #:init-keyword #:time #:accessor tick-time))

(define-class <worker-msg> ()
  (id #:init-keyword #:id #:accessor worker-id)
  (progress #:init-keyword #:progress #:accessor worker-progress))

(define-class <stats-msg> ()
  (cpu #:init-keyword #:cpu #:accessor cpu)
  (mem #:init-keyword #:mem #:accessor mem))

;;; Model - Dashboard state
(define-class <dashboard-model> ()
  (current-time #:init-keyword #:time #:init-value "" #:accessor current-time)
  (workers #:init-keyword #:workers #:init-value '() #:accessor workers)
  (cpu-usage #:init-keyword #:cpu #:init-value 0 #:accessor cpu-usage)
  (mem-usage #:init-keyword #:mem #:init-value 0 #:accessor mem-usage)
  (tick-count #:init-keyword #:tick #:init-value 0 #:accessor tick-count)
  (run-id #:init-keyword #:run-id #:init-value 0 #:accessor run-id))

;;; Init - spawn background workers
(define (init m)
  (let ((my-run-id (run-id m)))
    (batch-cmd
     ;; Clock ticker - updates every second
     (lambda ()
       (spawn-fiber
        (lambda ()
          (let loop ()
            (when (and (running? app) (= (run-id (model app)) my-run-id))
              (sleep 1)
              (let ((time-str (date->string (current-date) "~H:~M:~S")))
                (send-message app (make <tick-msg> #:time time-str)))
              (loop)))))
       #f)

     ;; Simulated workers - 3 concurrent tasks
     (lambda ()
       (let spawn-workers ((id 0))
         (when (< id 3)
           (spawn-fiber
            (lambda ()
              (let loop ((progress 0))
                (cond
                 ((>= progress 100)
                  (when (and (running? app) (= (run-id (model app)) my-run-id))
                    (send-message app (make <worker-msg> #:id id #:progress 100))))
                 ((and (running? app) (= (run-id (model app)) my-run-id))
                  (send-message app (make <worker-msg> #:id id #:progress progress))
                  (sleep (+ 0.1 (* id 0.1)))
                  (loop (+ progress (+ 1 (random 3)))))))))
           (spawn-workers (+ id 1))))
       #f)

     ;; Stats updater - random CPU/mem stats
     (lambda ()
       (spawn-fiber
        (lambda ()
          (let loop ()
            (when (and (running? app) (= (run-id (model app)) my-run-id))
              (sleep 0.5)
              (send-message app (make <stats-msg>
                                  #:cpu (+ 20 (random 60))
                                  #:mem (+ 30 (random 50))))
              (loop)))))
       #f))))

;;; Update - handle messages
(define (update m msg)
  (cond
   ;; Key messages
   ((is-a? msg <key-msg>)
    (case (key msg)
      ((#\q #\Q) (values m (quit-cmd)))
      ((#\r #\R)
       ;; Reset - increment run-id to stop old fibers, restart
       (set! (run-id m) (+ (run-id m) 1))
       (set! (workers m) '())
       (set! (tick-count m) 0)
       (values m (init m)))
      (else (values m #f))))

   ;; Clock tick
   ((is-a? msg <tick-msg>)
    (set! (current-time m) (tick-time msg))
    (set! (tick-count m) (+ (tick-count m) 1))
    (values m #f))

   ;; Worker progress update
   ((is-a? msg <worker-msg>)
    (let* ((id (worker-id msg))
           (progress (worker-progress msg))
           (existing (assoc id (workers m))))
      (if existing
          (set-cdr! existing progress)
          (set! (workers m)
                (cons (cons id progress) (workers m))))
      (values m #f)))

   ;; Stats update
   ((is-a? msg <stats-msg>)
    (set! (cpu-usage m) (cpu msg))
    (set! (mem-usage m) (mem msg))
    (values m #f))

   (else (values m #f))))

;;; View helpers
(define (progress-bar width percent)
  "Draw a progress bar"
  (let* ((filled (quotient (* width percent) 100))
         (empty (- width filled))
         (bar (string-append
               (make-string filled #\█)
               (make-string empty #\░))))
    bar))

(define (worker-line worker-pair)
  "Render a single worker"
  (let ((id (car worker-pair))
        (progress (cdr worker-pair)))
    (hbox
     (txt (string-append "Worker " (number->string id) ": ") #:fg 6)
     (if (>= progress 100)
         (txt "DONE" #:bold? #t #:fg 2)
         (hbox
          (progress-bar 20 progress)
          " "
          (txt (string-append (number->string progress) "%") #:fg 3))))))

;;; View - render dashboard
(define (view m)
  (vbox
   ;; Header
   (txt "═══════════════════════════════════════════════════════════" #:fg 5)
   (hbox
    (txt "  GUILE TUI DASHBOARD  " #:bold? #t #:fg 2)
    "  |  "
    (txt (current-time m) #:fg 3)
    "  |  "
    (txt (string-append "Ticks: " (number->string (tick-count m))) #:fg 8))
   (txt "═══════════════════════════════════════════════════════════" #:fg 5)
   (spacer 1)

   ;; System Stats
   (txt "SYSTEM STATS" #:bold? #t #:fg 4)
   (hbox "  CPU: " (progress-bar 15 (cpu-usage m))
         " " (txt (string-append (number->string (cpu-usage m)) "%") #:fg 3))
   (hbox "  MEM: " (progress-bar 15 (mem-usage m))
         " " (txt (string-append (number->string (mem-usage m)) "%") #:fg 3))
   (spacer 1)

   ;; Workers
   (txt "CONCURRENT WORKERS" #:bold? #t #:fg 4)
   (if (null? (workers m))
       (txt "  Starting workers..." #:fg 8)
       (apply vbox (map worker-line (reverse (workers m)))))
   (spacer 1)

   ;; Footer
   (txt "Controls:" #:fg 8)
   (txt "  r - Restart workers  |  q - Quit" #:fg 8)
   (spacer 1)
   (txt "Geiser: M-x geiser-connect RET localhost RET 37146" #:fg 8)
   (spacer 1)

   ;; Error console
   (error-console app)))

;;; Run
(define initial-model (make <dashboard-model>))
(define app (make-app initial-model (current-module)))
(run-app app)
