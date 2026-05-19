(define-module (canary app)
  #:use-module (canary terminal)
  #:use-module (canary protocol)
  #:use-module (canary input)
  #:use-module (canary component)
  #:use-module (canary backend)
  #:use-module (canary backend-ansi)
  #:use-module (canary render)
  #:use-module (canary keymap)
  #:use-module (canary keymap-input)
  #:use-module ((canary draw) #:select (make-clear))
  #:use-module (fibers)
  #:use-module (fibers channels)
  #:use-module (fibers operations)
  #:use-module ((fibers io-wakeup) #:select (wait-until-port-readable-operation))
  #:use-module ((fibers timers) #:select ((sleep . fiber-sleep)))
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 binary-ports)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:export (<app>
            make-app
            run-app
            send
            log-error
            get-errors
            app-model
            app-keymap
            app-backend
            app-running?
            set-app-keymap!
            at tail-from
            first second third fourth fifth
            sixth seventh eighth ninth tenth
            rest
            define-positions
            loop in-each))

(define-generic at)
(define-method (at (x <pair>)   n) (list-ref x n))
(define-method (at (x <vector>) n) (vector-ref x n))
(define-method (at (x <top>)    n)
  (if (struct? x)
      (struct-ref x n)
      (error "at: unsupported value" x)))
(define-method (at (x <object>) n)
  (slot-ref x (slot-definition-name
               (list-ref (class-slots (class-of x)) n))))

(define-generic tail-from)
(define-method (tail-from (x <pair>)   n) (list-tail x n))
(define-method (tail-from (x <vector>) n) (vector-copy x n))
(define-method (tail-from (x <object>) n)
  (map (lambda (s) (slot-ref x (slot-definition-name s)))
       (list-tail (class-slots (class-of x)) n)))

(define (first   x) (at x 0))
(define (second  x) (at x 1))
(define (third   x) (at x 2))
(define (fourth  x) (at x 3))
(define (fifth   x) (at x 4))
(define (sixth   x) (at x 5))
(define (seventh x) (at x 6))
(define (eighth  x) (at x 7))
(define (ninth   x) (at x 8))
(define (tenth   x) (at x 9))
(define (rest    x) (tail-from x 1))

(define-syntax-rule (define-positions (name idx) ...)
  (begin (define (name x) (at x idx)) ...))

(define-generic in-each)
(define-method (in-each proc (xs <pair>)) (for-each proc xs))
(define-method (in-each proc (xs <null>)) *unspecified*)
(define-method (in-each proc (v  <vector>))
  (let ((n (vector-length v)))
    (let lp ((i 0))
      (when (< i n) (proc (vector-ref v i)) (lp (+ i 1))))))

(define-syntax loop
  (lambda (stx)
    (define (kw=? s k)
      (let ((d (syntax->datum s)))
        (and (keyword? d) (eq? d k))))
    (syntax-case stx ()
      ((_ () body ...) #'(begin body ...))
      ((_ (kw t rest ...) body ...)
       (kw=? #'kw #:when)
       #'(when t (loop (rest ...) body ...)))
      ((_ (kw bs rest ...) body ...)
       (kw=? #'kw #:let)
       #'(let bs (loop (rest ...) body ...)))
      ((_ (v kw (lo hi step) rest ...) body ...)
       (kw=? #'kw #:range)
       #'(let lp ((v lo))
           (when (< v hi)
             (loop (rest ...) body ...)
             (lp (+ v step)))))
      ((_ (v kw (lo hi) rest ...) body ...)
       (kw=? #'kw #:range)
       #'(let lp ((v lo))
           (when (< v hi)
             (loop (rest ...) body ...)
             (lp (+ v 1)))))
      ((_ (v kw coll rest ...) body ...)
       (kw=? #'kw #:in)
       #'(in-each (lambda (v) (loop (rest ...) body ...)) coll))
      ((_ (v kw vec rest ...) body ...)
       (kw=? #'kw #:in-vec)
       #'(let* ((src vec)
                (n   (vector-length src)))
           (let lp ((i 0))
             (when (< i n)
               (let ((v (vector-ref src i)))
                 (loop (rest ...) body ...))
               (lp (+ i 1))))))
      ((_ (v kw ht rest ...) body ...)
       (kw=? #'kw #:keys)
       #'(hash-for-each (lambda (v _) (loop (rest ...) body ...)) ht))
      ((_ ((k v) kw ht rest ...) body ...)
       (kw=? #'kw #:pairs)
       #'(hash-for-each (lambda (k v) (loop (rest ...) body ...)) ht)))))

(define-class <app> ()
  (model    #:init-keyword #:model    #:accessor app-model)
  (init-fn  #:init-keyword #:init     #:accessor app-init)
  (update-fn #:init-keyword #:update  #:accessor app-update)
  (view-fn  #:init-keyword #:view     #:accessor app-view)
  (msg-ch   #:init-keyword #:msg-ch   #:accessor app-msg-ch)
  (stop-ch  #:init-keyword #:stop-ch  #:accessor app-stop-ch)
  (backend  #:init-keyword #:backend  #:accessor app-backend)
  (keymap   #:init-keyword #:keymap   #:accessor app-keymap)
  (running? #:init-value #t           #:accessor app-running?)
  (errors   #:init-value '()          #:accessor app-errors)
  (max-errors #:init-value 10         #:accessor app-max-errors))

(define* (make-app #:key
                   model
                   (init   (lambda (m) #f))
                   update
                   view
                   (backend (make-ansi-backend))
                   (keymap (keymap)))
  (make <app>
    #:model   model
    #:init    init
    #:update  update
    #:view    view
    #:msg-ch  (make-channel)
    #:stop-ch (make-channel)
    #:backend backend
    #:keymap  keymap))

(define (send app msg)
  (when (app-running? app)
    (put-message (app-msg-ch app) msg)))

(define (stop-app! app)
  (when (app-running? app)
    (set! (app-running? app) #f)
    (put-message (app-stop-ch app) 'stop)))

(define (set-app-keymap! app km)
  (set! (app-keymap app) km))

(define (log-error app msg)
  (let ((errs (app-errors app)))
    (set! (app-errors app)
          (take (cons msg errs)
                (min (app-max-errors app) (+ 1 (length errs)))))))

(define (get-errors app)
  (app-errors app))

(define +stderr-line-cap+ 4096)

(define (drain-stderr-pipe app rport)
  (let ((acc (make-bytevector +stderr-line-cap+ 0))
        (pos 0)
        (wait (wait-until-port-readable-operation rport)))
    (define (flush! truncated?)
      (when (positive? pos)
        (log-error app
                   (let ((s (utf8->string acc 0 pos)))
                     (if truncated? (string-append s " […truncated]") s)))
        (set! pos 0)))
    (let loop ()
      (when (app-running? app)
        (unless (char-ready? rport)
          (perform-operation wait))
        (let ((b (get-u8 rport)))
          (cond
           ((eof-object? b)
            (flush! #f)
            (loop))
           ((= b 10)
            (flush! #f)
            (loop))
           ((>= pos +stderr-line-cap+)
            (flush! #t)
            (loop))
           (else
            (bytevector-u8-set! acc pos b)
            (set! pos (+ pos 1))
            (loop))))))))

(define (render-frame app)
  (catch #t
    (lambda ()
      (let* ((sz   (backend-size (app-backend app)))
             (node ((app-view app) (app-model app) sz))
             (cmds (cons (make-clear) (render node (size-width sz) (size-height sz)))))
        (backend-draw (app-backend app) cmds)))
    (lambda (key . args)
      (log-error app (format #f "render: ~a ~a" key args)))))

(define (run-command app cmd)
  (cond
   ((not cmd) #f)
   ((eq? cmd 'quit) (stop-app! app))
   ((batch? cmd)
    (for-each (lambda (c) (run-command app c)) (cdr cmd)))
   ((sequence? cmd)
    (spawn-fiber
     (lambda ()
       (catch #t
         (lambda ()
           (for-each (lambda (c)
                       (when (and c (app-running? app))
                         (let ((msg (c)))
                           (when msg (send app msg)))))
                     (cdr cmd)))
         (lambda (key . args)
           (log-error app (format #f "~a: ~a" key args)))))))
   ((every? cmd)
    (let ((period   (cadr cmd))
          (producer (caddr cmd)))
      (spawn-fiber
       (lambda ()
         (let loop ()
           (when (app-running? app)
             (fiber-sleep period)
             (catch #t
               (lambda ()
                 (let ((msg (producer)))
                   (when msg (send app msg))))
               (lambda (key . args)
                 (log-error app (format #f "every: ~a ~a" key args))))
             (loop)))))))
   ((after? cmd)
    (let ((delay    (cadr cmd))
          (producer (caddr cmd)))
      (spawn-fiber
       (lambda ()
         (fiber-sleep delay)
         (when (app-running? app)
           (catch #t
             (lambda ()
               (let ((msg (producer)))
                 (when msg (send app msg))))
             (lambda (key . args)
               (log-error app (format #f "after: ~a ~a" key args)))))))))
   ((procedure? cmd)
    (spawn-fiber
     (lambda ()
       (catch #t
         (lambda ()
           (let ((msg (cmd)))
             (when msg (send app msg))))
         (lambda (key . args)
           (log-error app (format #f "~a: ~a" key args)))))))))

(define (input-loop app)
  (let ((wait (wait-until-port-readable-operation (current-input-port))))
    (let loop ((last-mouse-time 0))
      (when (app-running? app)
        (perform-operation wait)
        (let drain ((last-mouse-time last-mouse-time))
          (let ((msg (read-key-msg))
                (now (get-internal-real-time)))
            (cond
             ((not msg)
              (loop last-mouse-time))
             ((not (mouse? msg))
              (send app msg)
              (drain last-mouse-time))
             (else
              (let ((elapsed-ms (quotient (* (- now last-mouse-time) 1000)
                                          internal-time-units-per-second)))
                (cond
                 ((or (= last-mouse-time 0) (> elapsed-ms 16))
                  (send app msg)
                  (drain now))
                 (else
                  (drain last-mouse-time))))))))))))

(define (dispatch-to-user app msg)
  (let ((sz (backend-size (app-backend app))))
    (call-with-values
        (lambda () ((app-update app) (app-model app) msg sz))
      (lambda (new-model cmd)
        (set! (app-model app) new-model)
        (when cmd (run-command app cmd))))))

(define (event-loop app)
  (let loop ()
    (when (app-running? app)
      (let ((msg (get-message (app-msg-ch app))))
        (cond
         ((eq? msg 'quit)
          (stop-app! app))
         ((key? msg)
          (receive (action new-km) (feed-key (app-keymap app) msg)
            (set-app-keymap! app new-km)
            (cond
             ((eq? action 'pending) #f)
             ((eq? action 'quit)    (stop-app! app))
             (action                (dispatch-to-user app action)
                                    (render-frame app))
             (else                  (dispatch-to-user app msg)
                                    (render-frame app)))))
         (else
          (dispatch-to-user app msg)
          (render-frame app)))
        (when (app-running? app) (loop))))))

(define %dup2
  (pointer->procedure int
                      (dynamic-func "dup2" (dynamic-link))
                      (list int int)))

(define (run-app app)
  (let ((cleanup-done #f)
        (stderr-pipe (pipe))
        (saved-stderr-fd #f))
    (define (do-cleanup)
      (unless cleanup-done
        (set! cleanup-done #t)
        (backend-shutdown (app-backend app))
        (when saved-stderr-fd
          (%dup2 saved-stderr-fd 2))))

    (catch #t
      (lambda ()
        (dynamic-wind
          (lambda ()
            (set! saved-stderr-fd (%dup2 2 100))
            (%dup2 (port->fdes (cdr stderr-pipe)) 2)
            (backend-init (app-backend app))
            (setup-signal-handlers do-cleanup)
            (setup-resize-handler
             (lambda ()
               (let ((sz (backend-size (app-backend app))))
                 (when sz
                   (send app (resize (size-width sz) (size-height sz))))))))

          (lambda ()
            (run-fibers
             (lambda ()
               (spawn-fiber (lambda () (event-loop app)))
               (spawn-fiber (lambda () (input-loop app)))
               (let ((init-cmd ((app-init app) (app-model app))))
                 (when init-cmd (run-command app init-cmd)))
               (let ((sz (backend-size (app-backend app))))
                 (send app (resize (size-width sz) (size-height sz))))
               (spawn-fiber
                (lambda () (drain-stderr-pipe app (car stderr-pipe))))
               (get-message (app-stop-ch app)))
             #:hz 10))

          (lambda ()
            (do-cleanup))))

      (lambda (key . args)
        (do-cleanup)
        (apply throw key args)))))
