(define-module (canary app)
  #:use-module (canary terminal)
  #:use-module (canary protocol)
  #:use-module (canary input)
  #:use-module (canary component)
  #:use-module (canary backend)
  #:use-module (canary backend-ansi)
  #:use-module (canary theme)
  #:use-module (canary render)
  #:use-module (canary keymap)
  #:use-module (canary keymap-input)
  #:use-module ((canary view) #:select (make-text-node))
  #:use-module ((canary draw) #:select (make-clear))
  #:use-module ((canary layout) #:select (txt vbox width overlay pin))
  #:use-module ((canary borders) #:select (boxed border-rounded))
  #:use-module (fibers)
  #:use-module (fibers channels)
  #:use-module (fibers operations)
  #:use-module ((fibers io-wakeup) #:select (wait-until-port-readable-operation))
  #:use-module ((fibers timers) #:select ((sleep . fiber-sleep)))
  #:use-module (ice-9 threads)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 binary-ports)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:export (<app>
            run-app
            start-app!
            init update view
            send
            <log-entry> log-entry?
            log-entry-time log-entry-source log-entry-level log-entry-text
            log! clear-log!
            with-engine-error
            render-log
            app-keymap
            app-backend
            app-theme
            app-title
            app-running?
            app-log-entries app-show-log? app-log-cap app-log-height-frac
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
  ;; user-facing config (set at make-time)
  (title       #:init-keyword #:title       #:init-value #f
               #:accessor app-title)
  (keymap      #:init-keyword #:keymap      #:init-value #f
               #:accessor app-keymap)
  (theme       #:init-keyword #:theme       #:init-value #f
               #:accessor app-theme)
  (alt-screen? #:init-keyword #:alt-screen? #:init-value #t
               #:accessor app-alt-screen?)
  (cursor      #:init-keyword #:cursor      #:init-value 'hidden
               #:accessor app-cursor)
  (mouse       #:init-keyword #:mouse       #:init-value 'off
               #:accessor app-mouse)
  (filter      #:init-keyword #:filter      #:init-value #f
               #:accessor app-filter)
  (backend     #:init-keyword #:backend     #:init-value #f
               #:accessor app-backend)
  ;; log panel config
  (show-log?       #:init-keyword #:show-log?       #:init-value #t
                   #:accessor app-show-log?)
  (log-cap         #:init-keyword #:log-cap         #:init-value 200
                   #:accessor app-log-cap)
  (log-height-frac #:init-keyword #:log-height-frac #:init-value 1/5
                   #:accessor app-log-height-frac)
  (msg-queue   #:init-value '()              #:accessor app-msg-queue)
  (queue-mutex #:init-form (make-mutex)      #:accessor app-queue-mutex)
  (msg-bell    #:init-form (make-bell-pipe)  #:accessor app-msg-bell)
  (stop-ch     #:init-form (make-bell-pipe)  #:accessor app-stop-ch)
  (running?    #:init-value #t               #:accessor app-running?)
  (log-entries #:init-value '()              #:accessor app-log-entries))

(define (make-bell-pipe)
  (let ((p (pipe)))
    (set-port-encoding! (car p) "ISO-8859-1")
    (set-port-encoding! (cdr p) "ISO-8859-1")
    (setvbuf (cdr p) 'none)
    p))

(define (ring! bell)
  (write-char #\space (cdr bell))
  (force-output (cdr bell)))

(define (drain-bell! bell)
  (let ((rd (car bell)))
    (let loop ()
      (when (char-ready? rd)
        (read-char rd)
        (loop)))))

(define-generic init)
(define-generic update)
(define-generic view)

(define-method (init   (a <app>))         #f)
(define-method (update (a <app>) msg sz)  (values a #f))
(define-method (view   (a <app>) sz)      (make-text-node "" 'default '()))

(define-method (initialize (a <app>) initargs)
  (next-method)
  (unless (app-keymap a)  (set! (app-keymap  a) (keymap)))
  (unless (app-theme  a)  (set! (app-theme   a) default-theme))
  (unless (app-backend a)
    (set! (app-backend a) (make-ansi-backend #:theme (app-theme a))))
  ;; if both backend and theme were supplied, keep backend's theme in sync
  (when (and (app-theme a) (ansi-backend-theme (app-backend a)))
    (set-ansi-backend-theme! (app-backend a) (app-theme a))))

(define (send app msg)
  "Enqueue MSG and wake the event loop. Thread-safe: queue ops behind a
mutex, wakeup is a single byte to a pipe that the event-loop fiber
selects on. Callable from any Guile thread, no fibers scheduler
needed."
  (when (app-running? app)
    (with-mutex (app-queue-mutex app)
      (set! (app-msg-queue app) (cons msg (app-msg-queue app))))
    (ring! (app-msg-bell app))))

(define (drain-msgs! app)
  (with-mutex (app-queue-mutex app)
    (let ((q (app-msg-queue app)))
      (set! (app-msg-queue app) '())
      (reverse q))))

(define (stop-app! app)
  (when (app-running? app)
    (set! (app-running? app) #f)
    (ring! (app-msg-bell app))
    (ring! (app-stop-ch app))))

(define (set-app-keymap! app km)
  (set! (app-keymap app) km))

(define-record-type <log-entry>
  (make-log-entry time source level text)
  log-entry?
  (time   log-entry-time)
  (source log-entry-source)     ; 'update 'view 'render 'init 'cmd 'stderr 'exec 'user
  (level  log-entry-level)      ; 'info 'warn 'error
  (text   log-entry-text))

(define (log! app source level text)
  (let* ((entry (make-log-entry (current-time) source level text))
         (entries (cons entry (app-log-entries app)))
         (cap (app-log-cap app)))
    (set! (app-log-entries app)
          (if (> (length entries) cap) (take entries cap) entries))))

(define (clear-log! app)
  (set! (app-log-entries app) '()))

(define-syntax-rule (with-engine-error app source body ...)
  (catch #t (lambda () body ...)
    (lambda (k . a)
      (log! app source 'error (format #f "~a ~a" k a)))))

(define-generic render-log)
(define-method (render-log (a <app>) sz entries panel-h)
  (default-render-log sz entries panel-h))

(define (default-render-log sz entries panel-h)
  (let* ((cols   (size-width sz))
         (inner-w (max 1 (- cols 2)))
         (inner-h (max 1 (- panel-h 2)))
         (recent (if (> (length entries) inner-h)
                     (take entries inner-h)
                     entries))
         (lines  (reverse recent)))
    (boxed
     (apply vbox
            (map (lambda (e)
                   (width
                    (txt (format #f "[~a/~a] ~a"
                                 (log-entry-source e)
                                 (log-entry-level  e)
                                 (log-entry-text   e))
                         #:fg (case (log-entry-level e)
                                ((error) 'error)
                                ((warn)  'warning)
                                (else    'info)))
                    inner-w))
                 lines))
     #:border border-rounded
     #:fg 'muted)))

(define +stderr-line-cap+ 4096)

(define (drain-stderr-pipe app rport)
  (let ((acc (make-bytevector +stderr-line-cap+ 0))
        (pos 0)
        (wait (wait-until-port-readable-operation rport)))
    (define (flush! truncated?)
      (when (positive? pos)
        (log! app 'stderr 'warn
              (let* ((slice (make-bytevector pos))
                     (_ (bytevector-copy! acc 0 slice 0 pos))
                     (s (utf8->string slice)))
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

(define (compose-log-overlay app sz user-tree)
  (let ((entries (app-log-entries app)))
    (cond
     ((or (not (app-show-log? app)) (null? entries)) user-tree)
     (else
      (let* ((rows (size-height sz))
             (frac (app-log-height-frac app))
             (panel-h (max 4 (inexact->exact
                              (round (* rows (if (rational? frac)
                                                 frac (/ 1 5))))))))
        (overlay user-tree
                 (pin 0 (- rows panel-h)
                      (render-log app sz entries panel-h))))))))

(define (render-frame app)
  (catch #t
    (lambda ()
      (let* ((sz    (backend-size (app-backend app)))
             (user  (view app sz))
             (tree  (compose-log-overlay app sz user))
             (cmds  (cons (make-clear)
                          (render tree (size-width sz) (size-height sz)))))
        (backend-draw (app-backend app) cmds)))
    (lambda (key . args)
      ;; render itself threw — don't recurse into log (would loop); just stderr
      (format (current-error-port) "canary render failed: ~a ~a\n" key args))))

(define (run-command app cmd)
  (cond
   ((not cmd) #f)
   ((eq? cmd 'quit) (stop-app! app))
   ((clear-screen? cmd)
    (set! (ansi-backend-prev-term (app-backend app)) #f))
   ((set-title? cmd)
    (let ((out (ansi-backend-port (app-backend app))))
      (display (string-append "\x1b]0;" (set-title-text cmd) "\x07") out)
      (force-output out)))
   ((cursor? cmd)
    (let ((out (ansi-backend-port (app-backend app))))
      (case (cursor-mode cmd)
        ((hidden hide) (display "\x1b[?25l" out))
        ((visible show) (display "\x1b[?25h" out))
        ((bar) (display "\x1b[5 q" out))
        ((underline) (display "\x1b[3 q" out))
        ((block) (display "\x1b[1 q" out)))
      (force-output out)))
   ((alt-screen? cmd)
    (let ((out (ansi-backend-port (app-backend app))))
      (display (if (alt-screen-on? cmd) "\x1b[?1049h" "\x1b[?1049l") out)
      (force-output out)))
   ((mouse-mode? cmd)
    (let ((out (ansi-backend-port (app-backend app))))
      (case (mouse-mode-kind cmd)
        ((off)
         (display "\x1b[?1006l\x1b[?1015l\x1b[?1002l\x1b[?1003l\x1b[?1000l" out))
        ((click)
         (display "\x1b[?1003l\x1b[?1002l\x1b[?1000h\x1b[?1006h" out))
        ((cell)
         (display "\x1b[?1003l\x1b[?1002h\x1b[?1006h" out))
        ((all)
         (display "\x1b[?1003h\x1b[?1006h" out)))
      (force-output out)))
   ((println? cmd)
    (let ((out (ansi-backend-port (app-backend app)))
          (line (apply string-append
                       (map (lambda (p) (if (string? p) p (format #f "~a" p)))
                            (println-parts cmd)))))
      (display "\x1b[?1049l" out)
      (display line out)
      (newline out)
      (display "\x1b[?1049h" out)
      (set! (ansi-backend-prev-term (app-backend app)) #f)
      (force-output out)))
   ((set-palette? cmd)
    (let ((th (app-theme app)))
      (when (theme-set! th (set-palette-name cmd))
        (set! (ansi-backend-prev-term (app-backend app)) #f))))
   ((cycle-palette? cmd)
    (let ((th (app-theme app)))
      (theme-cycle! th)
      (set! (ansi-backend-prev-term (app-backend app)) #f)))
   ((clear-log? cmd) (clear-log! app))
   ((suspend? cmd)
    (let ((sigtstp 20))   ; Linux; macOS=18; fine as long as we match the build host for now
      (backend-shutdown (app-backend app))
      (kill (getpid) sigtstp)
      (backend-init (app-backend app))
      (send app (resumed))))
   ((exec? cmd)
    (let ((command (exec-command cmd))
          (on-done (exec-on-done cmd)))
      (backend-shutdown (app-backend app))
      (let ((status (system command)))
        (backend-init (app-backend app))
        (when on-done
          (let ((msg (on-done status)))
            (when msg (send app msg)))))))
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
           (log! app 'cmd 'error (format #f "~a ~a" key args)))))))
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
                 (log! app 'cmd 'error (format #f "every: ~a ~a" key args))))
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
               (log! app 'cmd 'error (format #f "after: ~a ~a" key args)))))))))
   ((procedure? cmd)
    (spawn-fiber
     (lambda ()
       (catch #t
         (lambda ()
           (let ((msg (cmd)))
             (when msg (send app msg))))
         (lambda (key . args)
           (log! app 'cmd 'error (format #f "~a ~a" key args)))))))))

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
  "Returns #t if MSG actually reached update, #f if filtered out."
  (catch #t
    (lambda ()
      (let* ((flt (app-filter app))
             (msg (if flt (flt msg) msg)))
        (cond
         ((not msg) #f)
         (else
          (let ((sz (backend-size (app-backend app))))
            (call-with-values
                (lambda () (update app msg sz))
              (lambda (new-app cmd)
                (when cmd (run-command app cmd)))))
          #t))))
    (lambda (key . args)
      (log! app 'update 'error (format #f "~a ~a" key args))
      #f)))

(define (process-one app msg)
  "Returns #t if MSG produced a real dispatch (update ran), #f if it
was a no-op (keymap pending/no-match with no fallback, or filter drop)."
  (cond
   ((eq? msg 'quit) (stop-app! app) #t)
   ((or (key? msg) (mouse? msg))
    (receive (action new-km) (feed-key (app-keymap app) msg)
      (set-app-keymap! app new-km)
      (cond
       ((eq? action 'pending) #f)
       ((eq? action 'quit)    (stop-app! app) #t)
       (action                (dispatch-to-user app action))
       (else                  (dispatch-to-user app msg)))))
   (else
    (dispatch-to-user app msg))))

(define (event-loop app)
  (let ((rd (car (app-msg-bell app))))
    (let loop ()
      (when (app-running? app)
        (perform-operation (wait-until-port-readable-operation rd))
        (drain-bell! (app-msg-bell app))
        (let* ((msgs (drain-msgs! app))
               (dispatched?
              (let lp ((ms msgs) (any? #f))
                (cond
                 ((null? ms) any?)
                 ((not (app-running? app)) any?)
                 (else
                  (let ((d? (process-one app (car ms))))
                    (lp (cdr ms) (or any? d?))))))))
        (when (and (app-running? app) dispatched?)
          (catch #t
            (lambda () (render-frame app))
            (lambda (key . args)
              (log! app 'render 'error (format #f "~a ~a" key args))))))
      (when (app-running? app) (loop))))))

(define %dup2
  (pointer->procedure int
                      (dynamic-func "dup2" (dynamic-link))
                      (list int int)))

(define (start-app! app)
  "Start APP inside an existing fibers scheduler. Spawns event-loop
and input-loop fibers, runs the app's init cmd, sends the initial
resize, then blocks on the stop-channel until the app is stopped.
Does NOT touch process-global state (signals, stderr capture); the
caller (an engine running multiple sessions in one image) owns that.
Returns when the app stops."
  (backend-init (app-backend app))
  (when (app-title app)
    (run-command app (set-title (app-title app))))
  (run-command app (cursor (app-cursor app)))
  (run-command app (mouse-mode (app-mouse app)))
  (unless (app-alt-screen? app)
    (run-command app (alt-screen 'off)))
  (let ((guarded (lambda (name thunk)
                   (lambda ()
                     (catch #t thunk
                       (lambda (key . args)
                         (log! app name 'error (format #f "~a ~a" key args))
                         (stop-app! app)))))))
    (spawn-fiber (guarded 'event-loop (lambda () (event-loop app))))
    (spawn-fiber (guarded 'input-loop (lambda () (input-loop app)))))
  (let ((init-cmd (init app)))
    (when init-cmd (run-command app init-cmd)))
  (let ((sz (backend-size (app-backend app))))
    (send app (resize (size-width sz) (size-height sz))))
  (perform-operation
   (wait-until-port-readable-operation (car (app-stop-ch app))))
  (backend-shutdown (app-backend app)))

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
            ;; apply app-level defaults at startup
            (when (app-title app)
              (run-command app (set-title (app-title app))))
            (run-command app (cursor (app-cursor app)))
            (run-command app (mouse-mode (app-mouse app)))
            (unless (app-alt-screen? app)
              (run-command app (alt-screen 'off)))
            (setup-signal-handlers do-cleanup)
            (setup-resize-handler
             (lambda ()
               (let ((sz (backend-size (app-backend app))))
                 (when sz
                   (send app (resize (size-width sz) (size-height sz))))))))

          (lambda ()
            (define (guarded name thunk)
              (lambda ()
                (catch #t thunk
                  (lambda (key . args)
                    (log! app name 'error (format #f "~a ~a" key args))
                    (stop-app! app)))))
            (run-fibers
             (lambda ()
               (spawn-fiber (guarded 'event-loop (lambda () (event-loop app))))
               (spawn-fiber (guarded 'input-loop (lambda () (input-loop app))))
               (let ((init-cmd (init app)))
                 (when init-cmd (run-command app init-cmd)))
               (let ((sz (backend-size (app-backend app))))
                 (send app (resize (size-width sz) (size-height sz))))
               (spawn-fiber
                (lambda () (drain-stderr-pipe app (car stderr-pipe))))
               (perform-operation
                (wait-until-port-readable-operation
                 (car (app-stop-ch app)))))
             #:hz 100))

          (lambda ()
            (do-cleanup))))

      (lambda (key . args)
        (write-crash-log app key args)
        (do-cleanup)
        (apply throw key args)))))

(define (write-crash-log app key args)
  (false-if-exception
   (let* ((cache (or (getenv "XDG_CACHE_HOME")
                     (string-append (or (getenv "HOME") "/tmp") "/.cache")))
          (dir   (string-append cache "/canary"))
          (file  (string-append dir "/last-crash.log")))
     (unless (file-exists? dir)
       (false-if-exception (mkdir dir)))
     (call-with-output-file file
       (lambda (p)
         (format p "=== canary crash @ ~a ===~%" (current-time))
         (format p "uncaught: ~a ~a~%~%" key args)
         (format p "=== log ring (~a entries, newest first) ===~%"
                 (length (app-log-entries app)))
         (for-each
          (lambda (e)
            (format p "~a [~a/~a] ~a~%"
                    (log-entry-time   e)
                    (log-entry-source e)
                    (log-entry-level  e)
                    (log-entry-text   e)))
          (app-log-entries app)))))))
