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
                                            <mount> mount <unmount> unmount
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
                                                   clickable-action
                                                   clickable-right-action))
  #:use-module ((canary layout) #:select (txt vbox width overlay pin))
  #:use-module ((canary borders) #:select (boxed border-rounded))
  #:use-module (fibers)
  #:use-module (fibers channels)
  #:use-module (fibers operations)
  #:use-module ((fibers io-wakeup) #:select (wait-until-port-readable-operation))
  #:use-module ((fibers timers) #:select ((sleep . fiber-sleep)
                                          sleep-operation))
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
            refresh-live-widgets!
            handle-resize!
            resize-flushed?
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
  "Append a log entry to ENG with origin SOURCE (a symbol like 'cmd
or 'render), LEVEL (a symbol like 'info, 'warn, 'error), and TEXT.
Trims to the engine's log-cap, dropping the oldest entries first."
  (let* ((entry   (make-log-entry (current-time) source level text))
         (entries (cons entry (engine-log-entries eng)))
         (cap     (engine-log-cap eng)))
    (set-engine-log-entries! eng
                             (if (> (length entries) cap) (take entries cap) entries))))

(define log! engine-log!)

;;; ── msg queue + bell ───────────────────────────────────────────────

(define (make-bell-pipe)
  "Return an unbuffered ISO-8859-1 pipe used as a cross-fiber wakeup
bell.  Writing any byte to the write end wakes a fiber blocked on
the read end via wait-until-port-readable."
  (let ((p (pipe)))
    (set-port-encoding! (car p) "ISO-8859-1")
    (set-port-encoding! (cdr p) "ISO-8859-1")
    (setvbuf (cdr p) 'none)
    p))

(define (ring! bell)
  "Write a byte to BELL's write end, waking any fiber waiting on
the read end."
  (write-char #\space (cdr bell))
  (force-output (cdr bell)))

(define (drain-bell! bell)
  "Consume any pending bytes on BELL's read end.  Called after a
wakeup so the next ring! actually triggers a wait."
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
  "Atomically take all enqueued msgs off ENG and return them in
send order (oldest first).  Resets the queue to empty."
  (with-mutex (engine-queue-mutex eng)
    (let ((q (engine-msg-queue eng)))
      (set-engine-msg-queue! eng '())
      (reverse q))))

(define (stop-engine! eng)
  "Mark ENG stopped and wake the event and input loops via their
bells so they can exit cleanly.  Safe to call from any fiber."
  (when (engine-running? eng)
    (set-engine-running?! eng #f)
    (ring! (engine-msg-bell eng))
    (ring! (engine-stop-ch eng))))

;;; ── log overlay ────────────────────────────────────────────────────

(define (default-render-log sz entries panel-h)
  "Return a boxed log-overlay panel view at SZ, showing the most
recent ENTRIES that fit in PANEL-H rows.  Source/level prefixes each
line; colour reflects level."
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
  "Pin the log overlay onto USER-TREE for engine ENG at size SZ.
No-op when log display is off or there are no entries.  Panel
height is engine-log-height-frac of total rows, minimum 4."
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

(define %debug-stderr (fdes->outport 100))

(define (render-frame eng)
  "Render one frame of ENG: compose user tree with log overlay,
flatten to draw cmds (preceded by a clear), split out clickable
regions for hit-testing, and hand the rest to the backend.  Errors
are logged, never raised."
  (format %debug-stderr "RENDER-FRAME called~%")
  (force-output %debug-stderr)
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
  "Walk the view tree rooted at NODE, calling PROC on every widget
encountered.  Descends through layout containers; uses SZ when
materialising lazy widget subviews via memoized-view.  Returns a
hashq used as the set of widgets seen during the walk — callers
that only want the side effects (cascade!) can ignore it; callers
that need the live set (refresh-live-widgets!) consume it."
  (let ((seen (make-hash-table)))
    (let walk ((node node))
      (cond
       ((not node) #f)
       ((string? node) #f)
       ((vbox-node? node)
        (for-each walk (vbox-node-items node)))
       ((hbox-node? node)
        (for-each walk (hbox-node-items node)))
       ((boxed-node? node)   (walk (boxed-node-body node)))
       ((pad-node? node)     (walk (pad-node-body node)))
       ((margin-node? node)  (walk (margin-node-body node)))
       ((align-node? node)   (walk (align-node-body node)))
       ((width-node? node)   (walk (width-node-body node)))
       ((height-node? node)  (walk (height-node-body node)))
       ((static-node? node)  (walk (static-node-body node)))
       ((click-node? node)   (walk (click-node-body node)))
       ((hover-node? node)   (walk (hover-node-body node)))
       ((flex-node? node)    (walk (flex-node-body node)))
       ((wrap-node? node)    #f)
       ((overlay-node? node)
        (walk (overlay-node-base node))
        (for-each (lambda (p) (walk (placement-body p)))
                  (overlay-node-overlays node)))
       ((is-a? node <object>)
        (hashq-set! seen node #t)
        (proc node)
        (walk (memoized-view node)))
       (else #f)))
    seen))

;;; ── input + dispatch ───────────────────────────────────────────────

(define (input-loop eng)
  "Read raw input from stdin and forward parsed msgs to ENG.  Coalesces
mouse motion at ≤60 Hz to avoid drowning the queue.  Waits on either
input arrival OR the engine's stop channel so stop-engine! can wake
this fiber without a stray byte (otherwise it would block until the
next keystroke, which never arrives once the session tears down — a
slow-motion fiber leak that starves the scheduler in long-lived
sessions)."
  (let ((wait-input (wait-until-port-readable-operation (current-input-port)))
        (wait-stop  (wait-until-port-readable-operation
                     (car (engine-stop-ch eng)))))
    (let loop ((last-mouse-time 0))
      (when (engine-running? eng)
        (perform-operation (choice-operation wait-input wait-stop))
        (when (engine-running? eng)
          (let drain ((last-mouse-time last-mouse-time))
            (let ((msg (read-key-msg))
                  (now (get-internal-real-time)))
              (cond
               ((not msg) (loop last-mouse-time))
               ((resize? msg)
                ;; ESC[8;rows;cols t reply: feed straight into the
                ;; debounce channel instead of the normal msg queue,
                ;; so drag-resize bursts coalesce.
                (put-message (engine-resize-channel eng) msg)
                (drain last-mouse-time))
               ((not (mouse? msg)) (send eng msg) (drain last-mouse-time))
               (else
                (let ((elapsed-ms (quotient (* (- now last-mouse-time) 1000)
                                            internal-time-units-per-second)))
                  (cond
                   ((or (= last-mouse-time 0) (> elapsed-ms 16))
                    (send eng msg) (drain now))
                   (else (drain last-mouse-time)))))))))))))

(define (find-click-region regions x y)
  "Return the topmost (last-added) click region in REGIONS whose
rect contains cell (X, Y), or #f if none.  Reverses so later
overlays win over earlier base layers."
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
  "Return #t if MSG is a left-button press or click."
  (and (mouse? msg)
       (eqv? (mouse-button msg) 0)
       (memq (mouse-action msg) '(press click))))

(define (mouse-right-press? msg)
  "Return #t if MSG is a right-button press or click."
  (and (mouse? msg)
       (eqv? (mouse-button msg) 2)
       (memq (mouse-action msg) '(press click))))

(define (note-mouse-pos! eng msg)
  "Update ENG's cached mouse coordinates from MSG.  Returns #t if
the cell changed, #f if unchanged — callers use this to decide
whether the next frame needs a re-render (e.g. for hover restyle)."
  (let ((nx (mouse-x msg)) (ny (mouse-y msg)))
    (cond
     ((and (= nx (engine-mouse-x eng)) (= ny (engine-mouse-y eng))) #f)
     (else
      (set-engine-mouse-x! eng nx)
      (set-engine-mouse-y! eng ny)
      #t))))

(define (dispatch-update! eng node msg cmds-cell)
  "Call (update node msg). Collect any cmd into CMDS-CELL (a 1-cons
list used as a mutable accumulator). Errors are logged, not raised.
Binds `%current-update-widget` so install-sub! can tag any
subscriptions installed during this call with their owning widget."
  (catch #t
    (lambda ()
      (parameterize ((%current-update-widget node))
        (call-with-values (lambda () (update node msg))
          (lambda vs
            (let ((cmd (cond ((null? vs) #f)
                             ((null? (cdr vs)) #f)
                             (else (cadr vs)))))
              (when cmd (set-car! cmds-cell (cons cmd (car cmds-cell))))))))
      (invalidate-size! node)
      (invalidate-cached-view! node))
    (lambda (key . args)
      (engine-log! eng 'update 'error (format #f "~a ~a" key args)))))

(define (cmds->batched cmds)
  "Collapse CMDS into a single cmd value for the engine to run.
Empty → #f; singleton → unwrap; multiple → a `batch` cmd.  Reverses
so cmds run in collection order."
  (cond
   ((null? cmds)       #f)
   ((null? (cdr cmds)) (car cmds))
   (else               (cons 'batch (reverse cmds)))))

(define (cascade! eng msg)
  "Broadcast MSG to every widget in ENG's tree (depth-first),
collecting their returned cmds.  Returns a single cmd (or #f) per
cmds->batched.  Used for app-level msgs that should reach all
widgets, not just the focused one."
  (let ((cmds-cell (list '()))
        (sz (backend-size (engine-backend eng))))
    (walk-nodes
     (engine-root eng)
     sz
     (lambda (node) (dispatch-update! eng node msg cmds-cell)))
    (cmds->batched (car cmds-cell))))

(define (unmount-widget! eng w cmds-cell)
  "Dispatch <unmount> to W and cancel every sub it installed."
  (dispatch-update! eng w (unmount) cmds-cell)
  (let ((ids (hashq-ref (engine-widget-subs eng) w '())))
    (for-each (lambda (id) (cancel-sub! eng id)) ids)))

(define (refresh-live-widgets! eng)
  "Diff ENG's current tree against the previous frame's live set.
Dispatch <mount> to widgets that just appeared and <unmount> to
widgets that just departed; auto-cancel any subs the departing
widgets owned.  Cmds returned by mount/unmount handlers are batched
and run."
  (let* ((seen (walk-nodes (engine-root eng)
                           (backend-size (engine-backend eng))
                           (lambda (_) #f)))
         (live (engine-live-widgets eng))
         (mounted   '())
         (unmounted '()))
    (hash-for-each
     (lambda (w _) (unless (hashq-ref live w) (set! mounted (cons w mounted))))
     seen)
    (hash-for-each
     (lambda (w _) (unless (hashq-ref seen w) (set! unmounted (cons w unmounted))))
     live)
    (when (or (pair? mounted) (pair? unmounted))
      (let ((cmds-cell (list '())))
        (for-each
         (lambda (w) (dispatch-update! eng w (mount) cmds-cell))
         mounted)
        (for-each (lambda (w) (unmount-widget! eng w cmds-cell)) unmounted)
        (let ((cmd (cmds->batched (car cmds-cell))))
          (when cmd (run-cmd! eng cmd)))))
    (set-engine-live-widgets! eng seen)))

(define (unmount-all! eng)
  "Cascade <unmount> to every widget in ENG's live set and cancel
their subs.  Called on engine shutdown so subscription fibers stop
cleanly instead of being left to leak."
  (let ((cmds-cell (list '()))
        (live      (engine-live-widgets eng)))
    (hash-for-each (lambda (w _) (unmount-widget! eng w cmds-cell)) live)
    (set-engine-live-widgets! eng (make-hash-table))
    (let ((cmd (cmds->batched (car cmds-cell))))
      (when cmd (run-cmd! eng cmd)))))

(define (find-focus-path root sz target)
  "Walk the source tree from ROOT looking for the widget TARGET.
Return (root-most-widget … target) — the path of widgets from
the outermost ancestor down to TARGET inclusive — or #f if TARGET is
not reachable. Layout records aren't in the path; only widget nodes."
  (define (try-list cs path)
    (cond ((null? cs) #f)
          (else (or (walk (car cs) path) (try-list (cdr cs) path)))))
  (define (walk node path)
    (cond
     ((not node) #f)
     ((string? node) #f)
     ((vbox-node? node)    (try-list (vbox-node-items node) path))
     ((hbox-node? node)    (try-list (hbox-node-items node) path))
     ((boxed-node? node)   (walk (boxed-node-body node) path))
     ((pad-node? node)     (walk (pad-node-body node) path))
     ((margin-node? node)  (walk (margin-node-body node) path))
     ((align-node? node)   (walk (align-node-body node) path))
     ((width-node? node)   (walk (width-node-body node) path))
     ((height-node? node)  (walk (height-node-body node) path))
     ((static-node? node)  (walk (static-node-body node) path))
     ((click-node? node)   (walk (click-node-body node) path))
     ((hover-node? node)   (walk (hover-node-body node) path))
     ((flex-node? node)    (walk (flex-node-body node) path))
     ((wrap-node? node)    #f)
     ((overlay-node? node)
      (or (walk (overlay-node-base node) path)
          (try-list (map placement-body (overlay-node-overlays node)) path)))
     ((is-a? node <object>)
      (let ((new-path (cons node path)))
        (cond
         ((eq? node target) (reverse new-path))
         (else (walk (memoized-view node) new-path)))))
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
       (lambda (node) (dispatch-update! eng node msg cmds-cell))
       targets))
    (cmds->batched (car cmds-cell))))

(define (make-sub-cell)
  "Return a fresh sub-cell: a 1-cons mutable cancel flag, initially
#f.  Sub fibers poll its car each iteration to decide whether to
exit."
  (list #f))

(define (sub-cell-stop! c)
  "Flip sub-cell C's cancel flag to #t so its fiber exits on next
poll."
  (set-car! c #t))

(define (sub-cell-stopped? c)
  "Return #t if sub-cell C has been cancelled."
  (car c))

;; The widget whose `update` is currently running, set by
;; dispatch-update! so install-sub! can tag the resulting subscription
;; with its owner.  When `update` returns, ownership goes back to #f
;; (no owner — anonymous sub).
(define %current-update-widget (make-parameter #f))

(define (install-sub! eng id kind fiber-body)
  "Install a sub identified by ID. KIND is 'every / 'after — used to
disambiguate in the subs hash (the cell value stores both for
debugging). FIBER-BODY is a thunk that takes the stop cell and runs
the producer loop. If ID is non-#f and already mapped, this is a
no-op — re-issuing the same sub from an update is idempotent.  When
called from inside a widget's update, the sub is also tagged with
that widget so unmounting auto-cancels it."
  (cond
   ((and id (hash-ref (engine-subs eng) id)) #f)
   (else
    (let ((cell  (make-sub-cell))
          (owner (%current-update-widget)))
      (when id (hash-set! (engine-subs eng) id cell))
      (when (and owner id)
        (let ((existing (hashq-ref (engine-widget-subs eng) owner '())))
          (unless (member id existing)
            (hashq-set! (engine-widget-subs eng) owner (cons id existing)))))
      (spawn-fiber (lambda () (fiber-body cell)))))))

(define (cancel-sub! eng id)
  "Cancel the sub on ENG tagged ID.  Stops its fiber, removes the
entry from the subs hash, and detaches it from its owning widget's
sub list if any.  No-op if ID isn't installed."
  (let ((cell (hash-ref (engine-subs eng) id)))
    (when cell
      (sub-cell-stop! cell)
      (hash-remove! (engine-subs eng) id)
      (hash-for-each
       (lambda (w ids)
         (when (member id ids)
           (let ((rest (filter (lambda (i) (not (equal? i id))) ids)))
             (if (null? rest)
                 (hashq-remove! (engine-widget-subs eng) w)
                 (hashq-set!    (engine-widget-subs eng) w rest)))))
       (engine-widget-subs eng)))))

(define (apply-filter eng msg)
  "Pass MSG through ENG's filter procedure if any, otherwise return
MSG unchanged.  Filters may return #f to drop the msg."
  (let ((f (engine-filter eng)))
    (if f (f msg) msg)))

(define (cmd-error! eng key args context)
  "Log an error on ENG for a cmd that raised: CONTEXT identifies
the cmd kind ('sequence / 'every / 'after / 'thunk); KEY and ARGS
are the catch payload."
  (engine-log! eng 'cmd 'error
               (format #f "~a: ~a ~a" context key args)))

(define (run-cmd! eng cmd)
  "Interpret one cmd CMD on engine ENG.  Dispatches on the cmd's
shape: bare symbols, tagged lists, and bare thunks.  Handles batch
fan-out, sequence (in-order async), every/after sub installation,
cancel, plus all screen and app cmds.  Unknown cmds are dropped."
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
      ('clear-log
       (set-engine-log-entries! eng '()))
      ('suspend
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

(define (handle-resize! eng msg)
  "Apply a flushed <resize> MSG: cache new dims on the backend,
invalidate the diff baseline, cascade to user code.  Called by the
debounce fiber after quiescence, and directly during bootstrap."
  (let ((b (engine-backend eng)))
    (when (ansi-backend? b)
      (set! (ansi-backend-size b)
            (size (resize-width msg) (resize-height msg)))
      (set! (ansi-backend-prev-term b) #f)))
  (let ((cmd (cascade! eng msg)))
    (run-cmd! eng cmd)))

(define (resize-flushed? msg)
  "Return #t if MSG is the internal wrapped form the debounce fiber
re-emits after quiescence."
  (and (pair? msg) (eq? (car msg) 'resize-flushed) (resize? (cdr msg))))

(define (process-one eng msg)
  (format %debug-stderr "PROCESS-ONE: ~s~%" msg)
  (force-output %debug-stderr)
  "Returns #t if anything reacted/should re-render, #f otherwise.

Routing policy:
- raw key/mouse msgs            → route-to-focus! (focus chain only)
- keymap-mapped action symbols  → cascade!        (broadcast — they're app intent, not keystrokes)
- on-click action symbols       → cascade!        (same reason)
- everything else (<init>, <tick>, <resize>, user msgs) → cascade!"
  (cond
   ((eq? msg 'quit) (stop-engine! eng) #t)
   ((resize-flushed? msg)
    (handle-resize! eng (cdr msg)) #t)
   ((resize? msg)
    ;; SIGWINCH path: the signal handler runs send eng to enqueue a
    ;; <resize>.  Re-route onto the debounce channel so drag-resize
    ;; bursts coalesce to one flushed resize per burst.
    (put-message (engine-resize-channel eng) msg)
    #f)
   ((mouse-left-press? msg)
    (note-mouse-pos! eng msg)
    (let ((hit (find-click-region (engine-click-regions eng)
                                  (mouse-x msg) (mouse-y msg))))
      (cond
       (hit
        (let ((action (clickable-action hit)))
          (cond
           ((not action)
            ;; left-press in a region with no left action → fall through
            ;; so raw mouse can flow to focus, e.g. the canvas drag.
            (let* ((m (apply-filter eng msg))
                   (cmd (and m (route-to-focus! eng m))))
              (run-cmd! eng cmd) #t))
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
   ((mouse-right-press? msg)
    ;; Right-press: same click-region machinery, but dispatch the
    ;; region's right-action. If the region has no right-action, fall
    ;; through to keymap then to raw routing (canvas sample, etc.).
    (note-mouse-pos! eng msg)
    (let ((hit (find-click-region (engine-click-regions eng)
                                  (mouse-x msg) (mouse-y msg))))
      (let ((right (and hit (clickable-right-action hit))))
        (cond
         (right
          (cond
           ((eq? right 'quit) (stop-engine! eng) #t)
           (else
            (let* ((m (apply-filter eng right))
                   (cmd (and m (cascade! eng m))))
              (run-cmd! eng cmd) #t))))
         (else
          (receive (action new-km) (feed-key (engine-keymap eng) msg)
            (set-engine-keymap! eng new-km)
            (cond
             ((eq? action 'pending) #f)
             ((eq? action 'quit) (stop-engine! eng) #t)
             (action (let* ((m (apply-filter eng action))
                            (cmd (and m (cascade! eng m))))
                       (run-cmd! eng cmd) #t))
             (else (let* ((m (apply-filter eng msg))
                          (cmd (and m (route-to-focus! eng m))))
                     (run-cmd! eng cmd) #t)))))))))
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
   ((and (key? msg)
         (pair? (engine-focus-chain eng))
         (pair? (cdr (engine-focus-chain eng))))
    (let* ((m (apply-filter eng msg))
           (cmd (and m (route-to-focus! eng m))))
      (run-cmd! eng cmd) #t))
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

(define +resize-debounce-seconds+ 0.05)

(define (resize-debounce-loop eng)
  "Receive <resize> msgs from ENG's resize-channel; coalesce any
bursts that arrive within a 50 ms quiescence window; emit one wrapped
<resize-flushed> back into the engine per burst.  Wakes on stop-ch
so shutdown can drop a fiber that would otherwise block on the
channel forever."
  (let ((ch      (engine-resize-channel eng))
        (stop-rd (car (engine-stop-ch eng))))
    (define (await-event timeout)
      "Block on the next channel msg, a stop signal, or the timeout.
Returns ('msg . resize), 'stop, or 'flush.  TIMEOUT in seconds, or
#f to wait indefinitely."
      (perform-operation
       (apply choice-operation
              (let ((ops (list
                          (wrap-operation (get-operation ch)
                                          (lambda (m) (cons 'msg m)))
                          (wrap-operation
                           (wait-until-port-readable-operation stop-rd)
                           (lambda _ 'stop)))))
                (if timeout
                    (cons (wrap-operation (sleep-operation timeout)
                                          (lambda _ 'flush))
                          ops)
                    ops)))))
    (let loop ()
      (when (engine-running? eng)
        (let ((first (await-event #f)))
          (cond
           ((eq? first 'stop) #f)
           (else
            (let coalesce ((latest (cdr first)))
              (let ((event (await-event +resize-debounce-seconds+)))
                (cond
                 ((eq? event 'stop) #f)
                 ((eq? event 'flush)
                  (when (engine-running? eng)
                    (send eng (cons 'resize-flushed latest)))
                  (loop))
                 (else (coalesce (cdr event))))))))))) ))

(define (event-loop eng)
  "Main message-processing loop for ENG.  Sleeps on the msg-bell,
drains the queue on wake, calls process-one on each msg, and
re-renders if any handler reported a state change.  Renders use a
fresh view cache per frame so widget subtrees don't leak across
frames."
  (let ((rd (car (engine-msg-bell eng))))
    (let loop ()
      (when (engine-running? eng)
        (perform-operation (wait-until-port-readable-operation rd))
        (drain-bell! (engine-msg-bell eng))
        ;; Cascade runs WITHOUT memoization — it descends into widgets
        ;; at the backend size to find nested instances, which would
        ;; pollute the cache and force render to see a backend-size
        ;; tree instead of the rect-size tree it needs. render-frame
        ;; gets its own cache below.
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
            (refresh-live-widgets! eng)
            (with-view-cache (make-hash-table)
              (lambda ()
               (catch #t
                 (lambda () (render-frame eng))
                 (lambda (key . args)
                   (engine-log! eng 'render 'error (format #f "~a ~a" key args))))))))
        (when (engine-running? eng) (loop))))))

;;; ── stderr capture (engine-owned, surfaces in log overlay) ─────────

(define +stderr-line-cap+ 4096)

(define (drain-stderr-pipe eng rport)
  "Read bytes from RPORT (read end of a stderr pipe) and surface
each complete line as a 'stderr 'warn log entry on ENG.  Truncates
individual lines at +stderr-line-cap+ bytes so a runaway producer
can't blow memory."
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
  "Run the cmds derived from ENG's initial configuration: window
title, cursor mode, mouse-reporting mode, and alt-screen toggle if
explicitly disabled."
  (when (engine-title eng)
    (run-cmd! eng (set-title (engine-title eng))))
  (run-cmd! eng (cursor (engine-cursor eng)))
  (run-cmd! eng (mouse-mode (engine-mouse-mode eng)))
  (unless (engine-alt-screen? eng)
    (run-cmd! eng (alt-screen 'off))))

(define (write-crash-log eng key args)
  "Dump a crash summary for ENG to $XDG_CACHE_HOME/canary/last-crash.log
when an uncaught exception escapes the top-level catch.  Includes
the throw key/args plus the in-memory log ring.  Wrapped in
false-if-exception so crash logging itself can't escalate."
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
    (spawn-fiber (guarded 'event-loop     (lambda () (event-loop eng))))
    (spawn-fiber (guarded 'input-loop     (lambda () (input-loop eng))))
    (spawn-fiber (guarded 'resize-debounce (lambda () (resize-debounce-loop eng)))))
  ;; Send <init> first so root react can return startup cmds (timers,
  ;; subscriptions, etc.) before any user input arrives. Then a resize
  ;; with the current backend size so the first render lays out
  ;; correctly.  Bootstrap resize bypasses the debounce — the first
  ;; frame needs real dimensions before anything else can render.
  (send eng (make <init>))
  (let ((sz (backend-size (engine-backend eng))))
    (send eng (cons 'resize-flushed
                    (resize (size-width sz) (size-height sz)))))
  (perform-operation
   (wait-until-port-readable-operation (car (engine-stop-ch eng))))
  (unmount-all! eng)
  (backend-shutdown (engine-backend eng)))

(define* (run-app root #:key title (keymap #f) (theme #f) (mouse 'off)
                  (cursor 'hidden) (alt-screen? #t) (filter #f) (backend #f)
                  (show-log? #t) (log-cap 200) (log-height-frac 1/5))
  "Run an app rooted at ROOT (a widget with a `view' method).
Kwargs: title, keymap, theme, mouse, cursor, alt-screen?, filter,
backend, plus log-overlay config."
  (let* ((b (or backend (ansi-backend #:theme (or theme default-theme))))
         (th (or theme default-theme))
         (km (or keymap (keymap)))
         (eng (engine #:backend b #:theme th #:keymap km #:title title
                           #:mouse-mode mouse #:cursor cursor
                           #:alt-screen? alt-screen? #:filter filter #:root root
                           #:msg-bell       (make-bell-pipe)
                           #:stop-ch        (make-bell-pipe)
                           #:resize-channel (make-channel)
                           #:log-cap log-cap #:show-log? show-log?
                           #:log-height-frac log-height-frac))
         (cleanup-done #f)
         (stderr-pipe (pipe))
         (saved-stderr-fd #f))
    (when (and th (ansi-backend? b))
      (set-ansi-backend-theme! b th))
    (define (do-cleanup)
      (unless cleanup-done
        (set! cleanup-done #t)
        (unmount-all! eng)
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
               ;; SIGWINCH → read size via TIOCGWINSZ and queue a
               ;; <resize> through the normal msg path (send eng).
               ;; process-one then puts it on resize-channel where
               ;; the debounce fiber sees it.  put-message can't run
               ;; here directly — it suspends on an unbuffered
               ;; channel, and Guile signal handlers must not block.
               (catch #t
                 (lambda ()
                   (let ((sz (get-terminal-size)))
                     (when sz
                       (send eng (resize (size-width sz)
                                         (size-height sz))))))
                 (lambda _ #f)))))
          (lambda ()
            (define (guarded name thunk)
              (lambda ()
                (catch #t thunk
                  (lambda (key . args)
                    (engine-log! eng name 'error (format #f "~a ~a" key args))
                    (stop-engine! eng)))))
            (run-fibers
             (lambda ()
               (spawn-fiber (guarded 'event-loop     (lambda () (event-loop eng))))
               (spawn-fiber (guarded 'input-loop     (lambda () (input-loop eng))))
               (spawn-fiber (guarded 'resize-debounce (lambda () (resize-debounce-loop eng))))
               (send eng (make <init>))
               (let ((sz (backend-size (engine-backend eng))))
                 (send eng (cons 'resize-flushed
                                 (resize (size-width sz) (size-height sz)))))
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

(define (ansi-backend? b)
  "Return #t if B is an <ansi-backend>.  Local helper because the
predicate isn't exported by (canary backend-ansi)."
  (is-a? b <ansi-backend>))
