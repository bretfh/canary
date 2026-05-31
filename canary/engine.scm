(define-module (canary engine)
  #:use-module (canary engine-types)
  #:use-module (canary widget)
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
                                            focus-in focus-in?
                                            focus-out focus-out?
                                            cancel cancel? cancel-id))
  #:use-module ((canary key) #:select (<key> key-sym key-mods key-event key=?))
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
  ;; Need srfi-1 list ops too, but `every`/`any`/`filter`/etc. would
  ;; clash with canary/protocol's `every` (the timer cmd constructor).
  ;; Prefix-import to keep them distinct.
  #:use-module ((srfi srfi-1) #:prefix list/)
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

(define (render-frame eng)
  "Render one frame of ENG: compose user tree with log overlay,
flatten to draw cmds (preceded by a clear), split out clickable
regions for hit-testing, and hand the rest to the backend.  Errors
are logged, never raised."
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
hashq of widgets seen during the walk."
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
       ((keymap-node? node)  (walk (keymap-node-body node)))
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
          (cond
           ((eof-object? (peek-char (current-input-port)))
            ;; Client gone.  Stop the engine so the per-session fiber
            ;; can return and dynamic-wind exits can run.
            (stop-engine! eng))
           (else
            (let drain ((last-mouse-time last-mouse-time))
              (let ((msg (read-key-msg))
                    (now (get-internal-real-time)))
                (cond
                 ((eof-object? msg) (stop-engine! eng))
                 ((not msg) (loop last-mouse-time))
                 ((resize? msg)
                  (put-message (engine-resize-channel eng) msg)
                  (drain last-mouse-time))
                 ((not (mouse? msg)) (send eng msg) (drain last-mouse-time))
                 (else
                  (let ((elapsed-ms (quotient (* (- now last-mouse-time) 1000)
                                              internal-time-units-per-second)))
                    (cond
                     ((or (= last-mouse-time 0) (> elapsed-ms 16))
                      (send eng msg) (drain now))
                     (else (drain last-mouse-time)))))))))))))))

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

(define (cmd-shape? x)
  "Return #t if X looks like a cmd the engine can run: a tagged list,
a known bare symbol, or a procedure (user thunk).  Used to filter
out unspecified / accidental non-cmd returns from update methods so
authors don't have to write a trailing #f."
  (or (procedure? x)
      (and (pair? x) (symbol? (car x)))
      (memq x '(quit clear-screen cycle-palette clear-log suspend))))

(define (cascade-value eng val msg cmds)
  "Dispatch MSG into VAL if VAL is a node, into each item if VAL is a
list of nodes, otherwise leave VAL alone.  Returns (cons new-val
cmds-with-any-collected-appended).  CMDS is the running list of cmds
the caller is accumulating; we cons new ones onto its front."
  (cond
   ((is-a? val <object>)
    (match (dispatch-update! eng val msg)
      ((new-val . new-cmd)
       (cons new-val (if new-cmd (cons new-cmd cmds) cmds)))))
   ((pair? val)
    (let loop ((rest val) (acc '()) (cmds cmds) (changed? #f))
      (cond
       ((pair? rest)
        (match (cascade-value eng (car rest) msg cmds)
          ((new-item . new-cmds)
           (loop (cdr rest)
                 (cons new-item acc)
                 new-cmds
                 (or changed? (not (eq? new-item (car rest))))))))
       (else
        (cons (if changed? (reverse acc) val) cmds)))))
   (else (cons val cmds))))

(define (cascade-into-slots eng node msg)
  "For each of NODE's slots that holds a node (directly or inside a
list), dispatch MSG into the contained node first and substitute the
returned value back into NODE.  Returns (cons rebuilt-node
list-of-child-cmds)."
  (let loop ((slots (class-slots (class-of node)))
             (overrides '())
             (cmds '()))
    (match slots
      (() (cons (if (null? overrides)
                    node
                    (apply update-slots node overrides))
                (reverse cmds)))
      ((slot . rest)
       (let* ((name (slot-definition-name slot))
              (val  (slot-ref node name)))
         (match (cascade-value eng val msg cmds)
           ((new-val . new-cmds)
            (cond
             ((eq? new-val val)
              (loop rest overrides new-cmds))
             (else
              (loop rest
                    (cons* (symbol->keyword name) new-val overrides)
                    new-cmds))))))))))

(define (dispatch-update! eng node msg)
  "Dispatch MSG to NODE: first cascade into any sub-nodes held in
NODE's slots, then call update on NODE with those sub-nodes already
updated.  Returns (cons new-node cmd-or-#f).  Errors are caught and
logged; on error, returns NODE unchanged."
  (catch #t
    (lambda ()
      (match (cascade-into-slots eng node msg)
        ((threaded . child-cmds)
         (parameterize ((%current-update-widget threaded))
           (let ((result (update threaded msg)))
             (match (if (pair? result) result (cons threaded #f))
               ((new-node . own-cmd)
                (invalidate-size! new-node)
                (invalidate-cached-view! new-node)
                (cons new-node
                      (cmds->batched
                       (if own-cmd (cons own-cmd child-cmds) child-cmds))))))))))
    (lambda (key . args)
      (engine-log! eng 'update 'error (format #f "~a ~a" key args))
      (cons node #f))))

(define (cmds->batched cmds)
  "Collapse CMDS into a single cmd value for the engine to run.
Empty → #f; singleton → unwrap; multiple → a `batch` cmd.  Reverses
so cmds run in collection order."
  (cond
   ((null? cmds)       #f)
   ((null? (cdr cmds)) (car cmds))
   (else               (cons 'batch (reverse cmds)))))

(define (walk-tree node visit)
  "Walk NODE recursively, calling (visit n) for each node encountered
that's a stateful instance (a GOOPS object).  Layout records and
lists are traversed transparently — their containers are not visited,
but anything inside them is."
  (let walk ((current node))
    (cond
     ((not current) #f)
     ((string? current) #f)
     ((is-a? current <object>)
      (visit current)
      (for-each
       (lambda (slot)
         (walk (slot-ref current (slot-definition-name slot))))
       (class-slots (class-of current))))
     ((vbox-node? current)    (for-each walk (vbox-node-items current)))
     ((hbox-node? current)    (for-each walk (hbox-node-items current)))
     ((boxed-node? current)   (walk (boxed-node-body current)))
     ((pad-node? current)     (walk (pad-node-body current)))
     ((margin-node? current)  (walk (margin-node-body current)))
     ((align-node? current)   (walk (align-node-body current)))
     ((width-node? current)   (walk (width-node-body current)))
     ((height-node? current)  (walk (height-node-body current)))
     ((static-node? current)  (walk (static-node-body current)))
     ((click-node? current)   (walk (click-node-body current)))
     ((hover-node? current)   (walk (hover-node-body current)))
     ((keymap-node? current)  (walk (keymap-node-body current)))
     ((link-node? current)    (walk (link-node-body current)))
     ((semantic-node? current) (walk (semantic-node-body current)))
     ((flex-node? current)    (walk (flex-node-body current)))
     ((overlay-node? current)
      (walk (overlay-node-base current))
      (for-each (lambda (p) (walk (placement-body p)))
                (overlay-node-overlays current)))
     ((pair? current)
      (walk (car current))
      (walk (cdr current)))
     (else #f))))

(define (build-id-map node)
  "Walk NODE recursively and return a hash table mapping each
focusable node's id to the node itself.  Used after the root has
been swapped so id-keyed bookkeeping (focus chain, live set, widget
subs) can resolve to current instances."
  (let ((tbl (make-hash-table)))
    (walk-tree node
               (lambda (n)
                 (when (is-a? n <focusable>)
                   (hash-set! tbl (widget-id n) n))))
    tbl))

(define (cascade! eng msg)
  "Broadcast MSG depth-first through every node held in slots reachable
from the engine root.  Swaps the root to the rebuilt tree and returns
the batched cmd."
  (match (dispatch-update! eng (engine-root eng) msg)
    ((new-root . cmd)
     (set-engine-root! eng new-root)
     cmd)))

(define (plain-update eng node msg)
  "Call update on NODE without cascading into its sub-nodes.  Returns
(cons new-node cmd-or-#f).  Errors are logged; on error the input
node is returned unchanged."
  (catch #t
    (lambda ()
      (parameterize ((%current-update-widget node))
        (let ((result (update node msg)))
          (if (pair? result) result (cons node #f)))))
    (lambda (key . args)
      (engine-log! eng 'update 'error (format #f "~a ~a" key args))
      (cons node #f))))

(define (search-each items id eng msg)
  "Walk each item in ITEMS searching for a focusable node with id ID;
rebuild the list if any item changed.  Returns (cons items-or-rebuilt
cmd-or-#f)."
  (let loop ((rest items) (acc '()) (changed? #f) (found-cmd #f))
    (cond
     ((pair? rest)
      (match (search-and-replace (car rest) id eng msg)
        ((new-item . new-cmd)
         (loop (cdr rest)
               (cons new-item acc)
               (or changed? (not (eq? new-item (car rest))))
               (or found-cmd new-cmd)))))
     (else
      (cons (if changed? (reverse acc) items) found-cmd)))))

(define (search-and-replace val id eng msg)
  "Recursively search VAL for a focusable node with widget-id ID; on
finding it, dispatch MSG on it and substitute the result back.
Returns (cons new-val cmd-or-#f).  Layout records are traversed
transparently — dispatch reaches widgets inside them but the layout
record itself is not rebuilt (it's transient anyway)."
  (cond
   ((not val) (cons val #f))
   ((string? val) (cons val #f))
   ((is-a? val <object>)
    (cond
     ((and (is-a? val <focusable>) (eq? (widget-id val) id))
      (plain-update eng val msg))
     (else
      (let loop ((slots (class-slots (class-of val)))
                 (overrides '())
                 (found-cmd #f))
        (match slots
          (() (cons (if (null? overrides)
                        val
                        (apply update-slots val overrides))
                    found-cmd))
          ((slot . rest)
           (let* ((name (slot-definition-name slot))
                  (sv   (slot-ref val name)))
             (match (search-and-replace sv id eng msg)
               ((new-sv . new-cmd)
                (cond
                 ((eq? new-sv sv)
                  (loop rest overrides (or found-cmd new-cmd)))
                 (else (loop rest
                             (cons* (symbol->keyword name) new-sv overrides)
                             (or found-cmd new-cmd)))))))))))))
   ((vbox-node? val)
    (match (search-each (vbox-node-items val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((hbox-node? val)
    (match (search-each (hbox-node-items val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((boxed-node? val)
    (match (search-and-replace (boxed-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((pad-node? val)
    (match (search-and-replace (pad-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((margin-node? val)
    (match (search-and-replace (margin-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((align-node? val)
    (match (search-and-replace (align-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((width-node? val)
    (match (search-and-replace (width-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((height-node? val)
    (match (search-and-replace (height-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((static-node? val)
    (match (search-and-replace (static-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((click-node? val)
    (match (search-and-replace (click-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((hover-node? val)
    (match (search-and-replace (hover-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((keymap-node? val)
    (match (search-and-replace (keymap-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((link-node? val)
    (match (search-and-replace (link-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((semantic-node? val)
    (match (search-and-replace (semantic-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((flex-node? val)
    (match (search-and-replace (flex-node-body val) id eng msg)
      ((_ . cmd) (cons val cmd))))
   ((overlay-node? val)
    (match (search-and-replace (overlay-node-base val) id eng msg)
      ((_ . cmd1)
       (match (search-each (map placement-body (overlay-node-overlays val))
                           id eng msg)
         ((_ . cmd2)
          (cons val (or cmd1 cmd2)))))))
   ((pair? val)
    (search-each val id eng msg))
   (else (cons val #f))))

(define (update-by-id eng root id msg)
  "Find the node with widget-id ID inside ROOT and dispatch MSG on it,
threading the result back through the tree.  When ID isn't present
the tree is returned unchanged.  Returns (cons new-root cmd-or-#f)."
  (search-and-replace root id eng msg))

(define (unmount-widget! eng id)
  "Dispatch <unmount> to the node with widget-id ID and cancel every
sub the node installed.  The departing node is read from the live
set (it's already gone from the current tree), so no threading is
needed."
  (let* ((live (engine-live-widgets eng))
         (node (hash-ref live id))
         (cmd  (and node (cdr (plain-update eng node (unmount))))))
    (let ((sub-ids (hash-ref (engine-widget-subs eng) id '())))
      (for-each (lambda (sid) (cancel-sub! eng sid)) sub-ids)
      (hash-remove! (engine-widget-subs eng) id))
    cmd))

(define (refresh-live-widgets! eng)
  "Diff the current root's id set against the prior frame's live set.
Dispatch <mount> to ids that just appeared and <unmount> to ids that
just departed; auto-cancel any subs the departing nodes owned.  Any
cmds returned by mount/unmount handlers are run."
  (let* ((seen-map (build-id-map (engine-root eng)))
         (live     (engine-live-widgets eng))
         (mounted-ids   '())
         (unmounted-ids '())
         (cmds '()))
    (hash-for-each
     (lambda (id _) (unless (hash-ref live id)
                      (set! mounted-ids (cons id mounted-ids))))
     seen-map)
    (hash-for-each
     (lambda (id _) (unless (hash-ref seen-map id)
                      (set! unmounted-ids (cons id unmounted-ids))))
     live)
    (for-each
     (lambda (id)
       (match (update-by-id eng (engine-root eng) id (mount))
         ((new-root . cmd)
          (set-engine-root! eng new-root)
          (when cmd (set! cmds (cons cmd cmds))))))
     mounted-ids)
    (for-each
     (lambda (id)
       (let ((cmd (unmount-widget! eng id)))
         (when cmd (set! cmds (cons cmd cmds)))))
     unmounted-ids)
    (let ((batched (cmds->batched cmds)))
      (when batched (run-cmd! eng batched)))
    (set-engine-live-widgets! eng (build-id-map (engine-root eng)))))

(define (unmount-all! eng)
  "Dispatch <unmount> to every node in the engine's live set on
shutdown so subscription fibers stop cleanly instead of leaking."
  (let ((cmds '()))
    (hash-for-each
     (lambda (id _)
       (let ((cmd (unmount-widget! eng id)))
         (when cmd (set! cmds (cons cmd cmds)))))
     (engine-live-widgets eng))
    (set-engine-live-widgets! eng (make-hash-table))
    (let ((batched (cmds->batched cmds)))
      (when batched (run-cmd! eng batched)))))

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
     ((keymap-node? node)  (walk (keymap-node-body node) path))
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

(define (collect-keymaps-on-focus-path eng)
  "Walk the engine's current root toward the focused leaf, collecting
every <keymap-node> wrapper found along the way INCLUDING ones inside
the focused widget's own view tree.  Returns the list of their
<keymap> values in priority order: innermost wrapper first (closest
to the focused widget), outermost last.  Returns '() when no widget is
focused or the focus chain is empty.

Three contribution sources:
- ancestor wrappers (a `with-keymap` around a parent's body that
  contains the focused widget);
- sibling-of-target wrappers (a `with-keymap` inside the focused
  widget's view, scoping its own binds);
- nested modal wrappers (a `with-keymap` inside the focused widget's
  view that itself wraps a further focused descendant)."
  (let* ((chain  (engine-focus-chain eng))
         (root   (engine-root eng))
         ;; Chain is stored root-first; the focused leaf is the last
         ;; element.
         (target-id (and (pair? chain) (car (last-pair chain)))))
    (cond
     ((not target-id) '())
     (else
      (let ((collected '())
            ;; #f while still descending toward target; #t once we're
            ;; inside the focused widget's own view tree.  In that
            ;; sub-walk every keymap-node collects unconditionally.
            (inside? #f))
        (define (try-list cs)
          (let lp ((rest cs) (any? #f))
            (cond ((null? rest) any?)
                  (else (lp (cdr rest) (or (walk (car rest)) any?))))))
        (define (walk node)
          (cond
           ((not node) #f)
           ((string? node) #f)
           ((vbox-node? node)    (try-list (vbox-node-items node)))
           ((hbox-node? node)    (try-list (hbox-node-items node)))
           ((boxed-node? node)   (walk (boxed-node-body node)))
           ((pad-node? node)     (walk (pad-node-body node)))
           ((margin-node? node)  (walk (margin-node-body node)))
           ((align-node? node)   (walk (align-node-body node)))
           ((width-node? node)   (walk (width-node-body node)))
           ((height-node? node)  (walk (height-node-body node)))
           ((static-node? node)  (walk (static-node-body node)))
           ((click-node? node)   (walk (click-node-body node)))
           ((hover-node? node)   (walk (hover-node-body node)))
           ((keymap-node? node)
            (cond
             (inside?
              ;; We're inside the focused widget's view; every
              ;; keymap-node along the way contributes regardless of
              ;; whether anything below matches.
              (walk (keymap-node-body node))
              (set! collected (cons (keymap-node-km node) collected))
              #t)
             ((walk (keymap-node-body node))
              ;; Ancestor wrapper that contains target somewhere.
              (set! collected (cons (keymap-node-km node) collected))
              #t)
             (else #f)))
           ((flex-node? node)    (walk (flex-node-body node)))
           ((wrap-node? node)    #f)
           ((overlay-node? node)
            (try-list (cons (overlay-node-base node)
                            (map placement-body (overlay-node-overlays node)))))
           ((is-a? node <object>)
            (cond
             ((and (not inside?)
                   (is-a? node <focusable>)
                   (eq? (widget-id node) target-id))
              ;; Hit the focused widget: descend into its view with
              ;; `inside?` set so keymap-nodes inside its view tree
              ;; collect unconditionally.  Restore inside? on the
              ;; way back so sibling branches at higher levels stay
              ;; in search mode.
              (let ((prev inside?))
                (set! inside? #t)
                (walk (memoized-view node))
                (set! inside? prev))
              #t)
             (else (walk (memoized-view node)))))
           (else #f)))
        (walk root)
        ;; Collected innermost-first naturally: post-order recursion
        ;; conses in unwind order from the deepest match back up.
        ;; Reverse so the returned priority order is innermost-first
        ;; (closest to focus = highest priority).
        (reverse collected))))))

;;; ── chord / combo handling ─────────────────────────────────────────
;;;
;;; Two kinds of keymap entries: <binding> (sequential, vim-style) and
;;; <combo-binding> (set, fires when all combo keys are held at once
;;; when one of them is pressed).  The engine sees the kitty keyboard
;;; protocol's press / release events (canary pushes flag bit 2 in
;;; backend-init) and tracks a held-set keyed by current time.  On
;;; press of a key K:
;;;
;;;   1. Add K to held.
;;;   2. If held exactly matches some combo's key-set → fire combo.
;;;   3. Else if some combo's key-set ⊋ held (a longer combo could
;;;      complete) AND K has a single-key action → defer that single
;;;      action.  Schedule an after-cmd timer; the timer's msg flushes
;;;      the pending action.  If a completing key arrives first, the
;;;      timer is cancelled and the combo fires instead.
;;;   4. Else fire single key normally.
;;;
;;; Release events drop K from held immediately.  On terminals without
;;; kitty release support, the held-set also self-prunes by time so a
;;; key that was pressed but no release ever arrived ages out after
;;; %chord-window-seconds.

;; Held-set safety net: only used when the terminal doesn't send a key-
;; release event for a key (legacy paths).  Real terminals on the kitty
;; keyboard protocol drive add/remove via press/release directly, and
;; this window is moot.  Keep it long enough that a held key isn't
;; pruned mid-chord even on slow paths.
(define %chord-window-seconds 5.0)
;; Defer window for a single-key action when a combo could still
;; complete.  100 ms covers a deliberate two-finger chord press
;; (humans land paired keys within 50–100 ms) while still firing the
;; single before the terminal's first key-repeat (~250 ms on Linux).
;; Tap-to-fire is immediate via the release event; this only matters
;; for the rare case where the user neither releases nor presses a
;; second key for 100 ms.
(define %chord-defer-ms       100)
(define %pending-flush-msg    'canary/chord-pending-flush)

(define (held-syms-of eng)
  "Return the list of <key>s currently held (just the keys, time
stripped)."
  (map car (engine-held-keys eng)))

(define (prune-held! eng)
  "Drop held entries older than the chord window.  Belt-and-braces for
terminals that don't send release events."
  (let* ((now (current-time))
         (kept (list/filter (lambda (entry)
                              (<= (- now (cdr entry)) %chord-window-seconds))
                            (engine-held-keys eng))))
    (set-engine-held-keys! eng kept)))

(define (add-to-held! eng k)
  "Add K to held with the current time, replacing any prior entry for
the same key."
  (let* ((others (list/filter (lambda (entry) (not (key=? (car entry) k)))
                              (engine-held-keys eng))))
    (set-engine-held-keys! eng (cons (cons k (current-time)) others))))

(define (remove-from-held! eng k)
  (set-engine-held-keys! eng
    (list/filter (lambda (entry) (not (key=? (car entry) k)))
                 (engine-held-keys eng))))

(define (combo-strict-superset? combo-key-list held-keys)
  "True if COMBO-KEY-LIST contains every key in HELD-KEYS and has at
least one additional key — i.e., this combo could complete if more
keys joined HELD-KEYS."
  (and (> (length combo-key-list) (length held-keys))
       (list/every (lambda (h) (list/any (lambda (c) (key=? c h))
                                          combo-key-list))
                   held-keys)))

(define (find-combo-action-on-stack eng held)
  "Walk the scoped + global keymap stack; return the first matching
combo action against HELD, or #f."
  (let* ((scoped (collect-keymaps-on-focus-path eng))
         (global (engine-keymap eng))
         (stack  (append scoped (if global (list global) '()))))
    (let lp ((rest stack))
      (cond
       ((null? rest) #f)
       ((keymap-match-combo (car rest) held) =>
        (lambda (action) action))
       (else (lp (cdr rest)))))))

(define (combo-possible-on-stack? eng held)
  "Return #t if any combo in the active keymap stack has a key-set
that strictly contains HELD — a press of one more key could complete
that combo."
  (let* ((scoped (collect-keymaps-on-focus-path eng))
         (global (engine-keymap eng))
         (stack  (append scoped (if global (list global) '())))
         (all-combos (list/append-map keymap-combos stack)))
    (list/any (lambda (c) (combo-strict-superset? (combo-keys c) held))
              all-combos)))

(define (cancel-pending-sub! eng)
  (let ((sid (engine-pending-sub-id eng)))
    (when sid (cancel-sub! eng sid)))
  (set-engine-pending-sub-id! eng #f))

(define (clear-pending! eng)
  "Drop pending state without firing.  Used when a combo subsumes the
deferred single."
  (cancel-pending-sub! eng)
  (set-engine-pending-key!    eng #f)
  (set-engine-pending-action! eng #f))

(define (fire-pending! eng)
  "Fire any pending single-key action via cascade; clear pending state.
No-op if nothing is pending."
  (let ((action (engine-pending-action eng)))
    (cancel-pending-sub! eng)
    (set-engine-pending-key!    eng #f)
    (set-engine-pending-action! eng #f)
    (when action
      (dispatch! eng cascade! (apply-filter eng action)))))

(define (schedule-pending-flush! eng)
  "Install an after-cmd that re-enqueues %pending-flush-msg after
%chord-defer-ms; remember its id so a completing combo or release can
cancel it."
  (let ((sid (gensym "canary/chord-")))
    (set-engine-pending-sub-id! eng sid)
    (run-cmd! eng
              (list 'after (/ %chord-defer-ms 1000)
                    (lambda () %pending-flush-msg)
                    sid))))

(define (dispatch-keymap-or-raw! eng msg)
  "Standard key dispatch: try the keymap stack, route to focus on no
match.  Returns #t if anything changed."
  (let ((action (try-keymap-stack! eng msg)))
    (cond
     ((eq? action 'pending) #f)
     ((eq? action 'quit) (stop-engine! eng) #t)
     (action (dispatch! eng cascade! (apply-filter eng action)))
     (else   (dispatch! eng route-to-focus! (apply-filter eng msg))))))

(define (key-already-held? eng msg)
  "Return #t if MSG's key is already in the held-set with no
intervening release.  Terminals like alacritty accept the kitty-kbd
flag-2 push but don't actually report event types — OS auto-repeats
arrive as identical 'press events.  Treating a press of a held key
as a repeat keeps the menu and other widgets that filter on 'press
from cycling per auto-repeat."
  (list/any (lambda (entry) (key=? (car entry) msg))
            (engine-held-keys eng)))

(define (handle-key-press! eng msg)
  "Chord-aware press handling.  Returns whether anything changed."
  (prune-held! eng)
  (cond
   ((key-already-held? eng msg)
    ;; Refresh the held timestamp so the entry doesn't prune mid-hold,
    ;; then route through the repeat path: clears any pending defer
    ;; (the user has committed) and dispatches with event=repeat so
    ;; widgets see the same shape as a kitty-reported repeat.
    (add-to-held! eng msg)
    (clear-pending! eng)
    (let ((rep (make <key>
                 #:sym   (key-sym msg)
                 #:mods  (key-mods msg)
                 #:event 'repeat)))
      (dispatch-keymap-or-raw! eng rep)))
   (else
    (handle-key-press-fresh! eng msg))))

(define (handle-key-press-fresh! eng msg)
  (add-to-held! eng msg)
  (let ((held (held-syms-of eng)))
    (cond
     ;; Exact combo match — fires immediately, drops any pending single.
     ;; Also drops the held-set: the two keys have been "consumed" by the
     ;; combo, so a stale entry (e.g. on terminals that don't send a
     ;; release event for the key) won't accidentally re-fire the same
     ;; combo on the next press.
     ((find-combo-action-on-stack eng held) =>
      (lambda (action)
        (clear-pending! eng)
        (set-engine-held-keys! eng '())
        (cond
         ((eq? action 'quit) (stop-engine! eng) #t)
         (else (dispatch! eng cascade! (apply-filter eng action))))))
     ;; A larger combo could still complete — defer this key's single
     ;; action if there is one, otherwise fall through.
     ((combo-possible-on-stack? eng held)
      (fire-pending! eng)
      (let ((action (try-keymap-stack! eng msg)))
        (cond
         ((eq? action 'pending) #f)
         ((eq? action 'quit) (stop-engine! eng) #t)
         (action
          (set-engine-pending-key!    eng msg)
          (set-engine-pending-action! eng action)
          (schedule-pending-flush! eng)
          #t)
         (else
          (dispatch! eng route-to-focus! (apply-filter eng msg))))))
     ;; No combo at play — drop any stale pending, dispatch normally.
     (else
      (fire-pending! eng)
      (dispatch-keymap-or-raw! eng msg)))))

(define (handle-key-release! eng msg)
  "Drop K from held.  If K was the deferred single, fire it now (the
user clearly released without forming a combo)."
  (remove-from-held! eng msg)
  (let ((pk (engine-pending-key eng)))
    (when (and pk (key=? pk msg))
      (fire-pending! eng))))

(define (try-keymap-stack! eng msg)
  "Feed MSG through the active keymap stack: scoped keymaps collected
on the focus path (innermost first), then the engine global keymap.
Returns the matched action (or 'pending, or #f).  Mutates the engine
global keymap via set-engine-keymap! to preserve chord state across
calls; scoped keymap chord state is not preserved across renders."
  (let* ((scoped (collect-keymaps-on-focus-path eng))
         (global (engine-keymap eng))
         (stack  (append scoped (if global (list global) '()))))
    (cond
     ((null? stack) #f)
     (else
      (call-with-values (lambda () (feed-key-stack stack msg))
        (lambda (action new-stack)
          (when (and global (pair? new-stack))
            ;; Engine global is the last entry; its chord state must
            ;; persist between dispatches.
            (set-engine-keymap! eng (car (last-pair new-stack))))
          action))))))

(define (route-to-focus! eng msg)
  "Dispatch MSG to the focus chain leaf-to-root.  Each id in the chain
resolves to the current node by id-map lookup; the node receives MSG
and the new node is threaded back into the root; subsequent ids see
the updated tree.  Stale ids (the node has departed since the chain
was set) are silently skipped.  Empty chain falls back to a full
broadcast from the root."
  (let* ((id-map (build-id-map (engine-root eng)))
         (chain  (engine-focus-chain eng))
         (cmds   '()))
    (cond
     ((null? chain)
      (match (dispatch-update! eng (engine-root eng) msg)
        ((new-root . cmd)
         (set-engine-root! eng new-root)
         cmd)))
     (else
      (for-each
       (lambda (id)
         (when (hash-ref id-map id)
           (match (update-by-id eng (engine-root eng) id msg)
             ((new-root . cmd)
              (set-engine-root! eng new-root)
              (set! id-map (build-id-map new-root))
              (when cmd (set! cmds (cons cmd cmds)))))))
       (reverse chain))
      (cmds->batched cmds)))))

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

(define %current-update-widget (make-parameter #f))

(define (install-sub! eng id kind fiber-body)
  "Install a sub identified by ID.  KIND is 'every / 'after.
FIBER-BODY is a thunk that takes the stop cell and runs the producer.
If ID is non-#f and already mapped, this is a no-op so re-issuing
the same sub from an update is idempotent.  When called from inside
a node's update, the sub is tagged with that node's widget-id so
unmount can auto-cancel it."
  (cond
   ((and id (hash-ref (engine-subs eng) id)) #f)
   (else
    (let* ((cell        (make-sub-cell))
           (owner       (%current-update-widget))
           (owner-id    (and owner
                             (is-a? owner <focusable>)
                             (widget-id owner))))
      (when id (hash-set! (engine-subs eng) id cell))
      (when (and owner-id id)
        (let ((existing (hash-ref (engine-widget-subs eng) owner-id '())))
          (unless (member id existing)
            (hash-set! (engine-widget-subs eng) owner-id (cons id existing)))))
      (spawn-fiber (lambda () (fiber-body cell)))))))

(define (cancel-sub! eng id)
  "Cancel the sub on ENG tagged ID.  Stops its fiber, removes the
entry from the subs hash, and detaches it from its owning node's
sub list if any.  No-op if ID isn't installed."
  (let ((cell (hash-ref (engine-subs eng) id)))
    (when cell
      (sub-cell-stop! cell)
      (hash-remove! (engine-subs eng) id)
      (hash-for-each
       (lambda (owner-id ids)
         (when (member id ids)
           (let ((rest (filter (lambda (i) (not (equal? i id))) ids)))
             (if (null? rest)
                 (hash-remove! (engine-widget-subs eng) owner-id)
                 (hash-set!    (engine-widget-subs eng) owner-id rest)))))
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
              (path (find-focus-path (engine-root eng) sz widget))
              (ids  (cond
                     ((not path) '())
                     (else (map widget-id
                                (filter (lambda (n) (is-a? n <focusable>))
                                        path)))))
              (prev (engine-focus-chain eng)))
         (set-engine-focus-chain! eng ids)
         ;; Dispatch widget-level focus events to anything that just
         ;; joined or just left the chain so its update method can
         ;; mirror the change locally (e.g. textinput's focused? slot).
         (for-each
          (lambda (id)
            (unless (member id prev)
              (match (update-by-id eng (engine-root eng) id (focus-in))
                ((new-root . cmd)
                 (set-engine-root! eng new-root)
                 (when cmd (run-cmd! eng cmd))))))
          ids)
         (for-each
          (lambda (id)
            (unless (member id ids)
              (match (update-by-id eng (engine-root eng) id (focus-out))
                ((new-root . cmd)
                 (set-engine-root! eng new-root)
                 (when cmd (run-cmd! eng cmd))))))
          prev)))
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

(define (dispatch! eng dispatcher m)
  "Run DISPATCHER (cascade! or route-to-focus!) for M, run any cmd it
returned, then report whether the engine root was actually rebuilt.
The root-rebuild check is the engine's @q{did anything change?}
signal — it works because @code{update-slots} short-circuits to the
input instance when every override matches, so a widget returning
@code{(cons self #f)} for a no-op tick lets the cascade skip the
rebuild all the way up to the root.  No state change → no render."
  (let* ((before (engine-root eng))
         (cmd    (and m (dispatcher eng m))))
    (run-cmd! eng cmd)
    (not (eq? before (engine-root eng)))))

(define (process-one eng msg)
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
            (dispatch! eng route-to-focus! (apply-filter eng msg)))
           ((eq? action 'quit) (stop-engine! eng) #t)
           (else
            (dispatch! eng cascade! (apply-filter eng action))))))
       (else
        (let ((action (try-keymap-stack! eng msg)))
          (cond
           ((eq? action 'pending) #f)
           ((eq? action 'quit) (stop-engine! eng) #t)
           (action (dispatch! eng cascade! (apply-filter eng action)))
           (else   (dispatch! eng route-to-focus! (apply-filter eng msg)))))))))
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
           (else (dispatch! eng cascade! (apply-filter eng right)))))
         (else
          (let ((action (try-keymap-stack! eng msg)))
            (cond
             ((eq? action 'pending) #f)
             ((eq? action 'quit) (stop-engine! eng) #t)
             (action (dispatch! eng cascade! (apply-filter eng action)))
             (else   (dispatch! eng route-to-focus! (apply-filter eng msg))))))))))
   ((and (mouse? msg) (eq? (mouse-action msg) 'motion))
    ;; Motion always updates the tracked cursor (for hover restyle). If
    ;; a button is held (low 2 bits != 3 = "no button"), also route to
    ;; focus so drag-to-X tools get the stream. Naked hover-only motion
    ;; stops at the position update.
    (let ((moved? (note-mouse-pos! eng msg))
          (drag?  (not (= 3 (logand (mouse-button msg) 3)))))
      (let ((changed?
             (and drag?
                  (dispatch! eng route-to-focus! (apply-filter eng msg)))))
        (or moved? changed?))))
   ;; Chord-aware key handling.  Releases drop from held-set + flush
   ;; pending single; repeats fire immediately bypassing the chord
   ;; defer (user is intentionally holding); presses go through the
   ;; combo-or-defer path.
   ((and (key? msg) (eq? (key-event msg) 'release))
    (handle-key-release! eng msg)
    #t)
   ((and (key? msg) (eq? (key-event msg) 'repeat))
    ;; Repeat = key is being held.  Drop any pending defer for it
    ;; (the user has committed) and fire the single immediately so
    ;; hold-to-move stays snappy.  Combo detection on repeat is
    ;; suppressed — it'd re-fire the same combo every repeat tick.
    (clear-pending! eng)
    (dispatch-keymap-or-raw! eng msg))
   ((eq? msg %pending-flush-msg)
    ;; The chord defer-window expired without a completing key —
    ;; commit the pending single-key action.
    (fire-pending! eng)
    #t)
   ((and (key? msg)
         (pair? (engine-focus-chain eng))
         (pair? (cdr (engine-focus-chain eng))))
    (handle-key-press! eng msg))
   ((key? msg)
    (handle-key-press! eng msg))
   ((mouse? msg)
    (note-mouse-pos! eng msg)
    (dispatch-keymap-or-raw! eng msg))
   (else
    (dispatch! eng cascade! (apply-filter eng msg)))))

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
frames.

  Per-cycle timing is reported to the backend via
  BACKEND-RECORD-CYCLE!; instrumented backends accumulate it for
  telemetry."
  (let ((rd (car (engine-msg-bell eng))))
    (let loop ()
      (when (engine-running? eng)
        (perform-operation (wait-until-port-readable-operation rd))
        (let ((t-wake (get-internal-real-time)))
          (drain-bell! (engine-msg-bell eng))
          (let* ((msgs (drain-msgs! eng))
                 (t-drain (get-internal-real-time))
                 (dispatched?
                  (let lp ((ms msgs) (any? #f))
                    (cond
                     ((null? ms) any?)
                     ((not (engine-running? eng)) any?)
                     (else
                      (let ((d? (process-one eng (car ms))))
                        (lp (cdr ms) (or any? d?)))))))
                 (t-process (get-internal-real-time)))
            (when (and (engine-running? eng) dispatched?)
              (refresh-live-widgets! eng)
              (with-view-cache (make-hash-table)
                (lambda ()
                 (catch #t
                   (lambda () (render-frame eng))
                   (lambda (key . args)
                     (engine-log! eng 'render 'error (format #f "~a ~a" key args)))))))
            (let ((t-end (get-internal-real-time)))
              (backend-record-cycle!
               (engine-backend eng)
               `((t-wake     . ,t-wake)
                 (drain-ns   . ,(- t-drain t-wake))
                 (process-ns . ,(- t-process t-drain))
                 (render-ns  . ,(- t-end t-process))
                 (cycle-ns   . ,(- t-end t-wake))
                 (msg-count  . ,(length msgs))
                 (dispatched? . ,dispatched?))))))
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
explicitly disabled.  These all emit terminal escapes; skip them when
the backend doesn't use stdin."
  (when (backend-uses-stdin? (engine-backend eng))
    (when (engine-title eng)
      (run-cmd! eng (set-title (engine-title eng))))
    (run-cmd! eng (cursor (engine-cursor eng)))
    (run-cmd! eng (mouse-mode (engine-mouse-mode eng)))
    (unless (engine-alt-screen? eng)
      (run-cmd! eng (alt-screen 'off)))))

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
  (let ((b (engine-backend eng)))
    (backend-set-engine! b eng)
    (backend-init b)
    (apply-startup-cmds! eng)
    (let ((guarded (lambda (name thunk)
                     (lambda ()
                       (catch #t thunk
                         (lambda (key . args)
                           (engine-log! eng name 'error
                                        (format #f "~a ~a" key args))
                           (stop-engine! eng)))))))
      (spawn-fiber (guarded 'event-loop
                            (lambda () (event-loop eng))))
      (when (backend-uses-stdin? b)
        (spawn-fiber (guarded 'input-loop
                              (lambda () (input-loop eng)))))
      (spawn-fiber (guarded 'resize-debounce
                            (lambda () (resize-debounce-loop eng))))))
  ;; Send <init> first so root react can return startup cmds (timers,
  ;; subscriptions, etc.) before any user input arrives. Then a resize
  ;; with the current backend size so the first render lays out
  ;; correctly.
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
            (when (backend-uses-stdin? b)
              (set! saved-stderr-fd (%dup2 2 100))
              (%dup2 (port->fdes (cdr stderr-pipe)) 2))
            (backend-set-engine! (engine-backend eng) eng)
            (backend-init (engine-backend eng))
            (apply-startup-cmds! eng)
            (when (backend-uses-stdin? b)
              (setup-signal-handlers do-cleanup)
              (setup-resize-handler
               (lambda ()
                 ;; Goes through send eng (mutex + pipe-write,
                 ;; signal-safe) rather than put-message on
                 ;; resize-channel directly: put-message suspends on
                 ;; unbuffered channels, and Guile signal handlers must
                 ;; not block.  process-one forwards the <resize> onto
                 ;; the channel where debounce sees it.
                 (catch #t
                   (lambda ()
                     (let ((sz (get-terminal-size)))
                       (when sz
                         (send eng (resize (size-width sz)
                                           (size-height sz))))))
                   (lambda _ #f))))))
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
               (when (backend-uses-stdin? b)
                 (spawn-fiber (guarded 'input-loop   (lambda () (input-loop eng)))))
               (spawn-fiber (guarded 'resize-debounce (lambda () (resize-debounce-loop eng))))
               (send eng (make <init>))
               (let ((sz (backend-size (engine-backend eng))))
                 (send eng (cons 'resize-flushed
                                 (resize (size-width sz) (size-height sz)))))
               (when (backend-uses-stdin? b)
                 (spawn-fiber
                  (lambda () (drain-stderr-pipe eng (car stderr-pipe)))))
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
