;;; app.scm --- TEA app runner with fibers

(define-module (tuition app)
  #:use-module (tuition terminal)
  #:use-module (tuition protocol)
  #:use-module (tuition input)
  #:use-module (tuition component)
  #:use-module (fibers)
  #:use-module (fibers channels)
  #:use-module (fibers timers)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 receive)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:export (<app>
            make-app
            run-app
            send-message
            log-error
            get-errors
            model
            user-module
            running?))

(define-class <app> ()
  (model #:init-keyword #:model #:accessor model)
  (user-module #:init-keyword #:user-module #:accessor user-module)
  (msg-ch #:init-keyword #:msg-ch #:accessor msg-ch)
  (running? #:init-keyword #:running? #:init-value #t #:accessor running?)
  (errors #:init-keyword #:errors #:init-value '() #:accessor errors)
  (max-errors #:init-keyword #:max-errors #:init-value 10 #:accessor max-errors)
  (dirty? #:init-keyword #:dirty? #:init-value #t #:accessor dirty?))

(define (make-app model user-module)
  "Create a new TEA app that dynamically looks up functions from user-module.
   The module should define: init, update, and view functions."
  (make <app>
    #:model model
    #:user-module user-module
    #:msg-ch (make-channel)
    #:running? #t))

(define (send-message app msg)
  "Send a message to the app's event loop"
  (when (running? app)
    (put-message (msg-ch app) msg)))

(define (log-error app msg)
  "Log an error message"
  (let ((errs (errors app)))
    (set! (errors app)
          (take (cons msg errs) (min (max-errors app) (+ 1 (length errs)))))))

(define (get-errors app)
  "Get list of logged errors (most recent first)"
  (errors app))

(define (render-view app)
  "Render the current view to the terminal"
  (catch #t
    (lambda ()
      (let* ((output (current-output-port))
             (view-fn (module-ref (user-module app) 'view))
             (content (view-fn (model app))))
        (display (string-append (csi "H") (csi "2J") content) output)
        (force-output output)))
    (lambda (key . args)
      (log-error app (format #f "render-view error: ~a ~a" key args)))))

(define (run-command app cmd)
  "Execute a command and send resulting message"
  (cond
   ;; No command
   ((not cmd) #f)

   ;; Batch commands - run concurrently
   ((and (pair? cmd) (eq? (car cmd) 'batch))
    (for-each (lambda (c) (run-command app c)) (cdr cmd)))

   ;; Sequence commands - run in order in a fiber
   ((and (pair? cmd) (eq? (car cmd) 'sequence))
    (spawn-fiber
     (lambda ()
       (catch #t
         (lambda ()
           (for-each (lambda (c)
                       (when (and c (running? app))
                         (let ((msg (c)))
                           (when msg (send-message app msg)))))
                     (cdr cmd)))
         (lambda (key . args)
           (log-error app (format #f "~a: ~a" key args)))))))

   ;; Single command function
   ((procedure? cmd)
    (spawn-fiber
     (lambda ()
       (catch #t
         (lambda ()
           (let ((msg (cmd)))
             (when msg (send-message app msg))))
         (lambda (key . args)
           (log-error app (format #f "~a: ~a" key args)))))))))

(define (input-loop app)
  (let loop ((last-mouse-time 0))
    (when (running? app)
      (let ((msg (read-key-msg))
            (now (get-internal-real-time)))
        (cond
         ;; Non-mouse messages: send immediately
         ((and msg (not (is-a? msg <mouse-msg>)))
          (send-message app msg)
          (usleep 10000)
          (loop last-mouse-time))
         ;; Mouse messages: throttle to ~60fps
         ((and msg (is-a? msg <mouse-msg>))
          (let ((elapsed-ms (quotient (* (- now last-mouse-time) 1000)
                                      internal-time-units-per-second)))
            (if (or (= last-mouse-time 0) (> elapsed-ms 16))
                (begin
                  (send-message app msg)
                  (usleep 10000)
                  (loop now))
                (begin
                  (usleep 10000)
                  (loop last-mouse-time)))))
         (else
          (usleep 10000)
          (loop last-mouse-time)))))))

(define (render-loop app)
  (let loop ()
    (when (running? app)
      (when (dirty? app)
        (render-view app)
        (set! (dirty? app) #f))
      (usleep 33333)
      (loop))))

(define (event-loop app)
  (let loop ()
    (when (running? app)
      (let ((msg (get-message (msg-ch app)))
            (update-fn (module-ref (user-module app) 'update)))
        (cond
         ((is-a? msg <quit-msg>)
          (set! (running? app) #f))
         (else
          ;; Try auto-delegating to focused components first
          (receive (delegated-model handled?)
              (auto-delegate-to-components (model app) msg)
            (set! (model app) delegated-model)
            (if handled?
                ;; Component handled it, just mark dirty
                (begin
                  (set! (dirty? app) #t)
                  (loop))
                ;; Component didn't handle, call user update
                (call-with-values
                    (lambda () (update-fn (model app) msg))
                  (lambda (new-model cmd)
                    (set! (model app) new-model)
                    (set! (dirty? app) #t)
                    (when cmd (run-command app cmd))
                    (loop)))))))))))

(define %dup2
  (pointer->procedure int
                      (dynamic-func "dup2" (dynamic-link))
                      (list int int)))

(define* (run-app app)
  "Run the app's main loop with fibers"
  (let ((cleanup-done #f)
        (stderr-pipe (pipe))
        (saved-stderr-fd #f))
    (define (do-cleanup)
      (unless cleanup-done
        (set! cleanup-done #t)
        (disable-mouse)
        (exit-alternate-screen)
        (show-cursor)
        (exit-raw-mode)
        (when saved-stderr-fd
          (%dup2 saved-stderr-fd 2))))

    (catch #t
      (lambda ()
        (dynamic-wind
          (lambda ()
            (set! saved-stderr-fd (%dup2 2 100))
            (%dup2 (port->fdes (cdr stderr-pipe)) 2)
            (enter-raw-mode)
            (enter-alternate-screen)
            (hide-cursor)
            (enable-mouse)
            (setup-signal-handlers do-cleanup))

          (lambda ()
            (run-fibers
             (lambda ()
               ;; Spawn fibers FIRST before sending any messages
               (spawn-fiber (lambda () (event-loop app)))
               (spawn-fiber (lambda () (input-loop app)))
               (spawn-fiber (lambda () (render-loop app)))
               ;; Call init
               (let* ((init-fn (module-ref (user-module app) 'init))
                      (init-cmd (init-fn (model app))))
                 (when init-cmd (run-command app init-cmd)))
               ;; Send initial window size
               (let ((size (get-terminal-size)))
                 (send-message app (make <window-size-msg>
                                     #:width (car size)
                                     #:height (cdr size))))
               (spawn-fiber
                (lambda ()
                  (let loop ()
                    (when (running? app)
                      (when (char-ready? (car stderr-pipe))
                        (let ((line (catch #t
                                      (lambda () (read-line (car stderr-pipe)))
                                      (lambda _ #f))))
                          (when (and line (not (eof-object? line)))
                            (log-error app line))))
                      (usleep 50000)
                      (loop)))))
               (let loop ()
                 (when (running? app)
                   (usleep 100000)
                   (loop))))
             #:hz 100))

          (lambda ()
            (do-cleanup))))

      (lambda (key . args)
        (do-cleanup)
        (apply throw key args)))))

