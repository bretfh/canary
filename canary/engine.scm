(define-module (canary engine)
  #:use-module (canary engine-types)
  #:use-module (canary cmd)
  #:use-module (canary terminal)
  #:use-module (canary protocol)
  #:use-module (canary input)
  #:use-module (canary backend)
  #:use-module (canary backend-ansi)
  #:use-module (canary theme)
  #:use-module (canary view)
  #:use-module (canary render)
  #:use-module (canary keymap)
  #:use-module (canary keymap-input)
  #:use-module ((canary draw) #:select (make-clear clickable-cmd?
                                                   clickable-col clickable-row
                                                   clickable-w clickable-h
                                                   clickable-action))
  #:use-module ((canary layout) #:select (txt vbox width overlay pin))
  #:use-module ((canary borders) #:select (boxed border-rounded))
  #:use-module (fibers)
  #:use-module (fibers channels)
  #:use-module (fibers operations)
  #:use-module ((fibers io-wakeup) #:select (wait-until-port-readable-operation))
  #:use-module ((fibers timers) #:select ((sleep . fiber-sleep)))
  #:use-module (ice-9 threads)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:use-module (oop goops)
  #:export (run-app
            start-engine!
            send
            stop-engine!
            <log-entry> log-entry? log-entry-time log-entry-source
            log-entry-level log-entry-text
            log! engine-log!))

;; engine.scm — owns the event loop, render pipeline, and msg dispatch.
;; Users never construct an <engine> directly. They call run-app with a
;; root node and optional kwargs; the engine wraps everything.
;;
;; The cascade: when a msg arrives, the engine walks the LAST RENDERED
;; node tree depth-first and calls react on every <stateful> node it
;; finds. No widget-children declaration — the tree IS the children.
;; Each react returns #f or a cmd; state mutates in place via the
;; setters. Cmds collected into a batch and
;; run after the cascade completes.

;;; ── log entries (engine-side, surfaced via log overlay) ────────────

(define-record-type <log-entry>
  (make-log-entry time source level text)
  log-entry?
  (time   log-entry-time)
  (source log-entry-source)
  (level  log-entry-level)
  (text   log-entry-text))

(define (engine-log! eng source level text)
  (let* ((entry   (make-log-entry (current-time) source level text))
         (entries (cons entry (engine-log-entries eng)))
         (cap     (engine-log-cap eng)))
    (set-engine-log-entries! eng
                             (if (> (length entries) cap) (take entries cap) entries))))

;; backward-compat alias used by some tests
(define log! engine-log!)

;;; ── msg queue + bell ───────────────────────────────────────────────

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
      (when (char-ready? rd) (read-char rd) (loop)))))

(define (send eng msg)
  "Enqueue MSG on ENG and wake the event loop. Thread-safe."
  (when (engine-running? eng)
    (with-mutex (engine-queue-mutex eng)
      (set-engine-msg-queue! eng (cons msg (engine-msg-queue eng))))
    (ring! (engine-msg-bell eng))))

(define (drain-msgs! eng)
  (with-mutex (engine-queue-mutex eng)
    (let ((q (engine-msg-queue eng)))
      (set-engine-msg-queue! eng '())
      (reverse q))))

(define (stop-engine! eng)
  (when (engine-running? eng)
    (set-engine-running?! eng #f)
    (ring! (engine-msg-bell eng))
    (ring! (engine-stop-ch eng))))

;;; ── log overlay ────────────────────────────────────────────────────

(define (default-render-log sz entries panel-h)
  (let* ((cols    (size-width sz))
         (inner-w (max 1 (- cols 2)))
         (inner-h (max 1 (- panel-h 2)))
         (recent  (if (> (length entries) inner-h) (take entries inner-h) entries))
         (lines   (reverse recent)))
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

(define (compose-log-overlay eng sz user-tree)
  (let ((entries (engine-log-entries eng)))
    (cond
     ((or (not (engine-show-log? eng)) (null? entries)) user-tree)
     (else
      (let* ((rows (size-height sz))
             (frac (engine-log-height-frac eng))
             (panel-h (max 4 (inexact->exact
                              (round (* rows (if (rational? frac) frac 1/5)))))))
        (overlay user-tree
                 (pin 0 (- rows panel-h)
                      (default-render-log sz entries panel-h))))))))

;;; ── render-frame ───────────────────────────────────────────────────

(define (render-frame eng)
  (catch #t
    (lambda ()
      (let* ((sz   (backend-size (engine-backend eng)))
             (tree (compose-log-overlay eng sz (engine-root eng)))
             (cmds (cons (make-clear)
                         (render tree (size-width sz) (size-height sz)
                                 #:mouse-x (engine-mouse-x eng)
                                 #:mouse-y (engine-mouse-y eng)))))
        (call-with-values (lambda () (partition clickable-cmd? cmds))
          (lambda (clicks draws)
            (set-engine-click-regions! eng clicks)
            (backend-draw (engine-backend eng) draws)))))
    (lambda (key . args)
      (format (current-error-port) "canary render failed: ~a ~a\n" key args))))

;;; ── tree walker for msg cascade ────────────────────────────────────

(define (walk-nodes node sz proc)
  (cond
   ((not node) #f)
   ((string? node) #f)
   ((vbox-node? node)
    (for-each (lambda (c) (walk-nodes c sz proc)) (vbox-node-children node)))
   ((hbox-node? node)
    (for-each (lambda (c) (walk-nodes c sz proc)) (hbox-node-children node)))
   ((boxed-node? node)   (walk-nodes (boxed-node-child node) sz proc))
   ((pad-node? node)     (walk-nodes (pad-node-child node) sz proc))
   ((margin-node? node)  (walk-nodes (margin-node-child node) sz proc))
   ((align-node? node)   (walk-nodes (align-node-child node) sz proc))
   ((width-node? node)   (walk-nodes (width-node-child node) sz proc))
   ((height-node? node)  (walk-nodes (height-node-child node) sz proc))
   ((static-node? node)  (walk-nodes (static-node-child node) sz proc))
   ((click-node? node)   (walk-nodes (click-node-child node) sz proc))
   ((hover-node? node)   (walk-nodes (hover-node-child node) sz proc))
   ((overlay-node? node)
    (walk-nodes (overlay-node-base node) sz proc)
    (for-each (lambda (p) (walk-nodes (placement-child p) sz proc))
              (overlay-node-overlays node)))
   ((is-a? node <object>)
    (proc node)
    (walk-nodes (view node sz) sz proc))
   (else #f)))

;;; ── input + dispatch ───────────────────────────────────────────────

(define (input-loop eng)
  (let ((wait (wait-until-port-readable-operation (current-input-port))))
    (let loop ((last-mouse-time 0))
      (when (engine-running? eng)
        (perform-operation wait)
        (let drain ((last-mouse-time last-mouse-time))
          (let ((msg (read-key-msg))
                (now (get-internal-real-time)))
            (cond
             ((not msg) (loop last-mouse-time))
             ((not (mouse? msg)) (send eng msg) (drain last-mouse-time))
             (else
              (let ((elapsed-ms (quotient (* (- now last-mouse-time) 1000)
                                          internal-time-units-per-second)))
                (cond
                 ((or (= last-mouse-time 0) (> elapsed-ms 16))
                  (send eng msg) (drain now))
                 (else (drain last-mouse-time))))))))))))

(define (find-click-region regions x y)
  (let lp ((rs (reverse regions)))
    (cond
     ((null? rs) #f)
     (else
      (let ((r (car rs)))
        (if (and (<= (clickable-col r) x)
                 (< x (+ (clickable-col r) (clickable-w r)))
                 (<= (clickable-row r) y)
                 (< y (+ (clickable-row r) (clickable-h r))))
            r
            (lp (cdr rs))))))))

(define (mouse-left-press? msg)
  (and (mouse? msg)
       (eqv? (mouse-button msg) 0)
       (memq (mouse-action msg) '(press click))))

(define (note-mouse-pos! eng msg)
  (let ((nx (mouse-x msg)) (ny (mouse-y msg)))
    (cond
     ((and (= nx (engine-mouse-x eng)) (= ny (engine-mouse-y eng))) #f)
     (else
      (set-engine-mouse-x! eng nx)
      (set-engine-mouse-y! eng ny)
      #t))))

(define (cascade! eng msg)
  (let ((cmds '())
        (sz (backend-size (engine-backend eng))))
    (walk-nodes
     (engine-root eng)
     sz
     (lambda (node)
       (catch #t
         (lambda ()
           (call-with-values (lambda () (update node msg sz))
             (lambda vs
               (let ((cmd (cond ((null? vs) #f)
                                ((null? (cdr vs)) #f)
                                (else (cadr vs)))))
                 (when cmd (set! cmds (cons cmd cmds))))))
           (invalidate-size! node))
         (lambda (key . args)
           (engine-log! eng 'update 'error (format #f "~a ~a" key args))))))
    (cond
     ((null? cmds)        #f)
     ((null? (cdr cmds))  (car cmds))
     (else                (cons 'batch (reverse cmds))))))

(define (apply-filter eng msg)
  (let ((f (engine-filter eng)))
    (if f (f msg) msg)))

(define (run-cmd! eng cmd)
  (when cmd
    (run-command eng cmd
                 (lambda (m) (send eng m))
                 (lambda () (stop-engine! eng))
                 (lambda (src lvl txt) (engine-log! eng src lvl txt)))))

(define (process-one eng msg)
  "Returns #t if anything reacted/should re-render, #f otherwise."
  (cond
   ((eq? msg 'quit) (stop-engine! eng) #t)
   ((mouse-left-press? msg)
    (note-mouse-pos! eng msg)
    (let ((hit (find-click-region (engine-click-regions eng)
                                  (mouse-x msg) (mouse-y msg))))
      (cond
       (hit
        (let ((action (clickable-action hit)))
          (cond
           ((eq? action 'quit) (stop-engine! eng) #t)
           (else
            (let* ((m (apply-filter eng action))
                   (cmd (and m (cascade! eng m))))
              (run-cmd! eng cmd)
              #t)))))
       (else
        (receive (action new-km) (feed-key (engine-keymap eng) msg)
          (set-engine-keymap! eng new-km)
          (cond
           ((eq? action 'pending) #f)
           ((eq? action 'quit) (stop-engine! eng) #t)
           (action (let* ((m (apply-filter eng action))
                          (cmd (and m (cascade! eng m))))
                     (run-cmd! eng cmd)
                     #t))
           (else (let* ((m (apply-filter eng msg))
                        (cmd (and m (cascade! eng m))))
                   (run-cmd! eng cmd)
                   #t))))))))
   ((and (mouse? msg) (eq? (mouse-action msg) 'motion))
    ;; Motion always updates the tracked cursor (for hover restyle). If
    ;; a button is held (low 2 bits != 3 = "no button"), also cascade so
    ;; drag-to-X tools (paint, lasso-select, …) get the stream. Naked
    ;; hover-only motion stops at the position update.
    (let ((moved? (note-mouse-pos! eng msg))
          (drag?  (not (= 3 (logand (mouse-button msg) 3)))))
      (when drag?
        (let* ((m   (apply-filter eng msg))
               (cmd (and m (cascade! eng m))))
          (run-cmd! eng cmd)))
      (or moved? drag?)))
   ((or (key? msg) (mouse? msg))
    (when (mouse? msg) (note-mouse-pos! eng msg))
    (receive (action new-km) (feed-key (engine-keymap eng) msg)
      (set-engine-keymap! eng new-km)
      (cond
       ((eq? action 'pending) #f)
       ((eq? action 'quit) (stop-engine! eng) #t)
       (action (let* ((m (apply-filter eng action))
                      (cmd (and m (cascade! eng m))))
                 (run-cmd! eng cmd)
                 #t))
       (else (let* ((m (apply-filter eng msg))
                    (cmd (and m (cascade! eng m))))
               (run-cmd! eng cmd)
               #t)))))
   (else
    (let* ((m (apply-filter eng msg))
           (cmd (and m (cascade! eng m))))
      (run-cmd! eng cmd)
      #t))))

(define (event-loop eng)
  (let ((rd (car (engine-msg-bell eng))))
    (let loop ()
      (when (engine-running? eng)
        (perform-operation (wait-until-port-readable-operation rd))
        (drain-bell! (engine-msg-bell eng))
        (let* ((msgs (drain-msgs! eng))
               (dispatched?
                (let lp ((ms msgs) (any? #f))
                  (cond
                   ((null? ms) any?)
                   ((not (engine-running? eng)) any?)
                   (else
                    (let ((d? (process-one eng (car ms))))
                      (lp (cdr ms) (or any? d?))))))))
          (when (and (engine-running? eng) dispatched?)
            (catch #t
              (lambda () (render-frame eng))
              (lambda (key . args)
                (engine-log! eng 'render 'error (format #f "~a ~a" key args))))))
        (when (engine-running? eng) (loop))))))

;;; ── stderr capture (engine-owned, surfaces in log overlay) ─────────

(define +stderr-line-cap+ 4096)

(define (drain-stderr-pipe eng rport)
  (let ((acc (make-bytevector +stderr-line-cap+ 0))
        (pos 0)
        (wait (wait-until-port-readable-operation rport)))
    (define (flush! truncated?)
      (when (positive? pos)
        (engine-log! eng 'stderr 'warn
                     (let* ((slice (make-bytevector pos))
                            (_ (bytevector-copy! acc 0 slice 0 pos))
                            (s (utf8->string slice)))
                       (if truncated? (string-append s " […truncated]") s)))
        (set! pos 0)))
    (let loop ()
      (when (engine-running? eng)
        (unless (char-ready? rport)
          (perform-operation wait))
        (let ((b (get-u8 rport)))
          (cond
           ((eof-object? b) (flush! #f) (loop))
           ((= b 10)        (flush! #f) (loop))
           ((>= pos +stderr-line-cap+) (flush! #t) (loop))
           (else (bytevector-u8-set! acc pos b)
                 (set! pos (+ pos 1)) (loop))))))))

;;; ── run-app ───────────────────────────────────────────────────────

(define %dup2
  (pointer->procedure int
                      (dynamic-func "dup2" (dynamic-link))
                      (list int int)))

(define (apply-startup-cmds! eng)
  (when (engine-title eng)
    (run-cmd! eng (set-title (engine-title eng))))
  (run-cmd! eng (cursor (engine-cursor eng)))
  (run-cmd! eng (mouse-mode (engine-mouse-mode eng)))
  (unless (engine-alt-screen? eng)
    (run-cmd! eng (alt-screen 'off))))

(define (write-crash-log eng key args)
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
                 (length (engine-log-entries eng)))
         (for-each
          (lambda (e)
            (format p "~a [~a/~a] ~a~%"
                    (log-entry-time   e) (log-entry-source e)
                    (log-entry-level  e) (log-entry-text   e)))
          (engine-log-entries eng)))))))

(define (start-engine! eng)
  "Start ENG inside an existing fibers scheduler. Returns when stopped.
Does NOT touch global state (signals, stderr) — caller (e.g. a multi-
session server) owns those."
  (backend-init (engine-backend eng))
  (apply-startup-cmds! eng)
  (let ((guarded (lambda (name thunk)
                   (lambda ()
                     (catch #t thunk
                       (lambda (key . args)
                         (engine-log! eng name 'error (format #f "~a ~a" key args))
                         (stop-engine! eng)))))))
    (spawn-fiber (guarded 'event-loop (lambda () (event-loop eng))))
    (spawn-fiber (guarded 'input-loop (lambda () (input-loop eng)))))
  ;; Send <init> first so root react can return startup cmds (timers,
  ;; subscriptions, etc.) before any user input arrives. Then a resize
  ;; with the current backend size so the first render lays out
  ;; correctly.
  (send eng (init))
  (let ((sz (backend-size (engine-backend eng))))
    (send eng (resize (size-width sz) (size-height sz))))
  (perform-operation
   (wait-until-port-readable-operation (car (engine-stop-ch eng))))
  (backend-shutdown (engine-backend eng)))

(define* (run-app root #:key title (keymap #f) (theme #f) (mouse 'off)
                  (cursor 'hidden) (alt-screen? #t) (filter #f) (backend #f)
                  (show-log? #t) (log-cap 200) (log-height-frac 1/5))
  "Run an app rooted at ROOT (a node — typically a stateful one).
Engine kwargs replace the old <app> slots: title, keymap, theme, mouse,
cursor, alt-screen?, filter, backend, plus log-overlay config."
  (let* ((b (or backend (make-ansi-backend #:theme (or theme default-theme))))
         (th (or theme default-theme))
         (km (or keymap (keymap)))
         (eng (make-engine #:backend b #:theme th #:keymap km #:title title
                           #:mouse-mode mouse #:cursor cursor
                           #:alt-screen? alt-screen? #:filter filter #:root root
                           #:msg-bell (make-bell-pipe)
                           #:stop-ch  (make-bell-pipe)
                           #:log-cap log-cap #:show-log? show-log?
                           #:log-height-frac log-height-frac))
         (cleanup-done #f)
         (stderr-pipe (pipe))
         (saved-stderr-fd #f))
    ;; Keep backend's theme in sync
    (when (and th (ansi-backend? b))
      (set-ansi-backend-theme! b th))
    (define (do-cleanup)
      (unless cleanup-done
        (set! cleanup-done #t)
        (backend-shutdown (engine-backend eng))
        (when saved-stderr-fd (%dup2 saved-stderr-fd 2))))
    (catch #t
      (lambda ()
        (dynamic-wind
          (lambda ()
            (set! saved-stderr-fd (%dup2 2 100))
            (%dup2 (port->fdes (cdr stderr-pipe)) 2)
            (backend-init (engine-backend eng))
            (apply-startup-cmds! eng)
            (setup-signal-handlers do-cleanup)
            (setup-resize-handler
             (lambda ()
               (let ((sz (backend-size (engine-backend eng))))
                 (when sz (send eng (resize (size-width sz) (size-height sz))))))))
          (lambda ()
            (define (guarded name thunk)
              (lambda ()
                (catch #t thunk
                  (lambda (key . args)
                    (engine-log! eng name 'error (format #f "~a ~a" key args))
                    (stop-engine! eng)))))
            (run-fibers
             (lambda ()
               (spawn-fiber (guarded 'event-loop (lambda () (event-loop eng))))
               (spawn-fiber (guarded 'input-loop (lambda () (input-loop eng))))
               ;; <init> first → root react returns startup cmds.
               (send eng (init))
               (let ((sz (backend-size (engine-backend eng))))
                 (send eng (resize (size-width sz) (size-height sz))))
               (spawn-fiber
                (lambda () (drain-stderr-pipe eng (car stderr-pipe))))
               (perform-operation
                (wait-until-port-readable-operation (car (engine-stop-ch eng)))))
             #:hz 100))
          (lambda () (do-cleanup))))
      (lambda (key . args)
        (write-crash-log eng key args)
        (do-cleanup)
        (apply throw key args)))))

;; ansi-backend? helper (predicate not exported by backend-ansi)
(define (ansi-backend? b) (is-a? b <ansi-backend>))
