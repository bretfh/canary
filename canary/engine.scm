(define-module (canary engine)
  #:use-module (canary engine-types)
  #:use-module (canary terminal)
  #:use-module ((canary protocol) #:select (<size> size size? size-width size-height
                                            <mouse> mouse mouse? mouse-x mouse-y
                                            mouse-button mouse-action
                                            <key> key? key-sym key-mods
                                            <tick> tick tick? tick-n
                                            <resize> resize resize? resize-width resize-height
                                            <init> init?
                                            batch sequence batch? sequence?
                                            every every? after after?
                                            set-title cursor alt-screen mouse-mode
                                            println suspend exec set-palette cycle-palette
                                            clear-log resumed
                                            focus focus? focus-target
                                            cancel cancel? cancel-id))
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
  #:use-module (ice-9 match)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module ((srfi srfi-1) #:select (take partition))
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
   ((flex-node? node)    (walk-nodes (flex-node-body node) sz proc))
   ((overlay-node? node)
    (walk-nodes (overlay-node-base node) sz proc)
    (for-each (lambda (p) (walk-nodes (placement-child p) sz proc))
              (overlay-node-overlays node)))
   ((is-a? node <object>)
    (proc node)
    (walk-nodes (memoized-view node sz) sz proc))
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

(define (dispatch-update! eng node msg sz cmds-cell)
  "Call (update node msg sz). Collect any cmd into CMDS-CELL (a 1-cons
list used as a mutable accumulator). Errors are logged, not raised."
  (catch #t
    (lambda ()
      (call-with-values (lambda () (update node msg sz))
        (lambda vs
          (let ((cmd (cond ((null? vs) #f)
                           ((null? (cdr vs)) #f)
                           (else (cadr vs)))))
            (when cmd (set-car! cmds-cell (cons cmd (car cmds-cell)))))))
      (invalidate-size! node)
      (invalidate-cached-view! node))
    (lambda (key . args)
      (engine-log! eng 'update 'error (format #f "~a ~a" key args)))))

(define (cmds->batched cmds)
  (cond
   ((null? cmds)       #f)
   ((null? (cdr cmds)) (car cmds))
   (else               (cons 'batch (reverse cmds)))))

(define (cascade! eng msg)
  (let ((cmds-cell (list '()))
        (sz (backend-size (engine-backend eng))))
    (walk-nodes
     (engine-root eng)
     sz
     (lambda (node) (dispatch-update! eng node msg sz cmds-cell)))
    (cmds->batched (car cmds-cell))))

(define (find-focus-path root sz target)
  "Walk the source tree from ROOT looking for the GOOPS instance TARGET.
Return (root-most-goops … target) — the path of GOOPS instances from
the outermost ancestor down to TARGET inclusive — or #f if TARGET is
not reachable. Layout records aren't in the path; only GOOPS nodes."
  (define (try-list cs path)
    (cond ((null? cs) #f)
          (else (or (walk (car cs) path) (try-list (cdr cs) path)))))
  (define (walk node path)
    (cond
     ((not node) #f)
     ((string? node) #f)
     ((vbox-node? node)    (try-list (vbox-node-children node) path))
     ((hbox-node? node)    (try-list (hbox-node-children node) path))
     ((boxed-node? node)   (walk (boxed-node-child node) path))
     ((pad-node? node)     (walk (pad-node-child node) path))
     ((margin-node? node)  (walk (margin-node-child node) path))
     ((align-node? node)   (walk (align-node-child node) path))
     ((width-node? node)   (walk (width-node-child node) path))
     ((height-node? node)  (walk (height-node-child node) path))
     ((static-node? node)  (walk (static-node-child node) path))
     ((click-node? node)   (walk (click-node-child node) path))
     ((hover-node? node)   (walk (hover-node-child node) path))
     ((flex-node? node)    (walk (flex-node-body node) path))
     ((overlay-node? node)
      (or (walk (overlay-node-base node) path)
          (try-list (map placement-child (overlay-node-overlays node)) path)))
     ((is-a? node <object>)
      (let ((new-path (cons node path)))
        (cond
         ((eq? node target) (reverse new-path))
         (else (walk (memoized-view node sz) new-path)))))
     (else #f)))
  (walk root '()))

(define (route-to-focus! eng msg)
  "Dispatch MSG to the focus chain leaf-to-root. If the chain is empty,
the root is the focus. Each node in the chain gets a call to update;
cmds returned are collected and batched. Stale chain entries (widgets
no longer in the tree) still receive the msg — they just produce no
visible effect — until the next (focus …) cmd refreshes the chain."
  (let ((cmds-cell (list '()))
        (sz (backend-size (engine-backend eng)))
        (chain (engine-focus-chain eng)))
    (let ((targets (cond
                    ((null? chain) (list (engine-root eng)))
                    (else (reverse chain)))))
      (for-each
       (lambda (node) (dispatch-update! eng node msg sz cmds-cell))
       targets))
    (cmds->batched (car cmds-cell))))

;; A sub-cell is a 1-element mutable box used by sub fibers to check if
;; they've been canceled. The cancel mechanism is cooperative: the
;; fiber's loop reads (car cell) after each iteration / before sending,
;; and exits if #t. Canceling sets it to #t and removes the id from
;; the engine's subs hash.

(define (make-sub-cell) (list #f))
(define (sub-cell-stop! c) (set-car! c #t))
(define (sub-cell-stopped? c) (car c))

(define (install-sub! eng id kind fiber-body)
  "Install a sub identified by ID. KIND is 'every / 'after — used to
disambiguate in the subs hash (the cell value stores both for
debugging). FIBER-BODY is a thunk that takes the stop cell and runs
the producer loop. If ID is non-#f and already mapped, this is a
no-op — re-issuing the same sub from an update is idempotent."
  (cond
   ((and id (hash-ref (engine-subs eng) id)) #f)
   (else
    (let ((cell (make-sub-cell)))
      (when id (hash-set! (engine-subs eng) id cell))
      (spawn-fiber (lambda () (fiber-body cell)))))))

(define (cancel-sub! eng id)
  (let ((cell (hash-ref (engine-subs eng) id)))
    (when cell
      (sub-cell-stop! cell)
      (hash-remove! (engine-subs eng) id))))

(define (apply-filter eng msg)
  (let ((f (engine-filter eng)))
    (if f (f msg) msg)))

(define (cmd-error! eng key args context)
  (engine-log! eng 'cmd 'error
               (format #f "~a: ~a ~a" context key args)))

(define (run-cmd! eng cmd)
  (let ((out (lambda () (ansi-backend-port (engine-backend eng))))
        (mark-dirty! (lambda ()
                       (set! (ansi-backend-prev-term (engine-backend eng)) #f))))
    (match cmd
      (#f #f)
      ('quit (stop-engine! eng))
      ('clear-screen (mark-dirty!))
      ('cycle-palette
       (theme-cycle! (engine-theme eng))
       (mark-dirty!))
      ('clear-log-cmd
       (set-engine-log-entries! eng '()))
      ('suspend-cmd
       (backend-shutdown (engine-backend eng))
       (kill (getpid) 20)                                ; Linux SIGTSTP
       (backend-init (engine-backend eng))
       (send eng (resumed)))
      (('set-title text)
       (let ((o (out)))
         (display (string-append "\x1b]0;" text "\x07") o)
         (force-output o)))
      (('cursor mode)
       (let ((o (out)))
         (case mode
           ((hidden hide)  (display "\x1b[?25l" o))
           ((visible show) (display "\x1b[?25h" o))
           ((bar)          (display "\x1b[5 q"  o))
           ((underline)    (display "\x1b[3 q"  o))
           ((block)        (display "\x1b[1 q"  o)))
         (force-output o)))
      (('alt-screen mode)
       (let ((o (out)))
         (display (if (eq? mode 'on) "\x1b[?1049h" "\x1b[?1049l") o)
         (force-output o)))
      (('mouse-mode mode)
       (let ((o (out)))
         (case mode
           ((off)
            (display "\x1b[?1006l\x1b[?1015l\x1b[?1002l\x1b[?1003l\x1b[?1000l" o))
           ((click)
            (display "\x1b[?1003l\x1b[?1002l\x1b[?1000h\x1b[?1006h" o))
           ((cell)
            (display "\x1b[?1003l\x1b[?1002h\x1b[?1006h" o))
           ((all)
            (display "\x1b[?1003h\x1b[?1006h" o)))
         (force-output o)))
      (('println . parts)
       (let ((o (out))
             (line (apply string-append
                          (map (lambda (p) (if (string? p) p (format #f "~a" p)))
                               parts))))
         (display "\x1b[?1049l" o)
         (display line o)
         (newline o)
         (display "\x1b[?1049h" o)
         (mark-dirty!)
         (force-output o)))
      (('set-palette name)
       (when (theme-set! (engine-theme eng) name) (mark-dirty!)))
      (('focus widget)
       (let* ((sz   (backend-size (engine-backend eng)))
              (path (find-focus-path (engine-root eng) sz widget)))
         (set-engine-focus-chain! eng (or path '()))))
      (('exec command on-done)
       (backend-shutdown (engine-backend eng))
       (let ((status (system command)))
         (backend-init (engine-backend eng))
         (when on-done
           (let ((msg (on-done status)))
             (when msg (send eng msg))))))
      (('batch . cmds)
       (for-each (lambda (c) (run-cmd! eng c)) cmds))
      (('sequence . cmds)
       (spawn-fiber
        (lambda ()
          (catch #t
            (lambda ()
              (for-each (lambda (c)
                          (when (and c (engine-running? eng))
                            (let ((msg (c)))
                              (when msg (send eng msg)))))
                        cmds))
            (lambda (key . args) (cmd-error! eng key args 'sequence))))))
      (('every period producer id)
       (install-sub!
        eng id 'every
        (lambda (cell)
          (let loop ()
            (when (and (engine-running? eng) (not (sub-cell-stopped? cell)))
              (fiber-sleep period)
              (when (and (engine-running? eng) (not (sub-cell-stopped? cell)))
                (catch #t
                  (lambda ()
                    (let ((msg (producer)))
                      (when msg (send eng msg))))
                  (lambda (key . args) (cmd-error! eng key args 'every)))
                (loop)))))))
      (('after delay producer id)
       (install-sub!
        eng id 'after
        (lambda (cell)
          (fiber-sleep delay)
          (when (and (engine-running? eng) (not (sub-cell-stopped? cell)))
            (catch #t
              (lambda ()
                (let ((msg (producer)))
                  (when msg (send eng msg))))
              (lambda (key . args) (cmd-error! eng key args 'after))))
          (when id (hash-remove! (engine-subs eng) id)))))
      (('cancel id) (cancel-sub! eng id))
      ((? procedure?)
       (spawn-fiber
        (lambda ()
          (catch #t
            (lambda ()
              (let ((msg (cmd)))
                (when msg (send eng msg))))
            (lambda (key . args) (cmd-error! eng key args 'thunk))))))
      (_ #f))))

(define (process-one eng msg)
  "Returns #t if anything reacted/should re-render, #f otherwise.

Routing policy:
- raw key/mouse msgs            → route-to-focus! (focus chain only)
- keymap-mapped action symbols  → cascade!        (broadcast — they're app intent, not keystrokes)
- on-click action symbols       → cascade!        (same reason)
- everything else (<init>, <tick>, <resize>, user msgs) → cascade!"
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
                        (cmd (and m (route-to-focus! eng m))))
                   (run-cmd! eng cmd)
                   #t))))))))
   ((and (mouse? msg) (eq? (mouse-action msg) 'motion))
    ;; Motion always updates the tracked cursor (for hover restyle). If
    ;; a button is held (low 2 bits != 3 = "no button"), also route to
    ;; focus so drag-to-X tools get the stream. Naked hover-only motion
    ;; stops at the position update.
    (let ((moved? (note-mouse-pos! eng msg))
          (drag?  (not (= 3 (logand (mouse-button msg) 3)))))
      (when drag?
        (let* ((m   (apply-filter eng msg))
               (cmd (and m (route-to-focus! eng m))))
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
                    (cmd (and m (route-to-focus! eng m))))
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
        (with-view-cache
         (make-hash-table)
         (lambda ()
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
                   (engine-log! eng 'render 'error (format #f "~a ~a" key args))))))))
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
  (send eng (make <init>))
  (let ((sz (backend-size (engine-backend eng))))
    (send eng (resize (size-width sz) (size-height sz))))
  (perform-operation
   (wait-until-port-readable-operation (car (engine-stop-ch eng))))
  (backend-shutdown (engine-backend eng)))

(define* (run-app root #:key title (keymap #f) (theme #f) (mouse 'off)
                  (cursor 'hidden) (alt-screen? #t) (filter #f) (backend #f)
                  (show-log? #t) (log-cap 200) (log-height-frac 1/5))
  "Run an app rooted at ROOT (a GOOPS instance with a `view' method).
Kwargs: title, keymap, theme, mouse, cursor, alt-screen?, filter,
backend, plus log-overlay config."
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
               (send eng (make <init>))
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
