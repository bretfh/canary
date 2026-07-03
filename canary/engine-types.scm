(define-module (canary engine-types)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 threads)
  #:use-module (fibers channels)
  #:export (<engine>
            engine
            engine?
            engine-backend     set-engine-backend!
            engine-theme       set-engine-theme!
            engine-keymap      set-engine-keymap!
            engine-title       set-engine-title!
            engine-mouse-mode  set-engine-mouse-mode!
            engine-cursor      set-engine-cursor!
            engine-alt-screen? set-engine-alt-screen?!
            engine-filter      set-engine-filter!
            engine-root        set-engine-root!
            engine-running?    set-engine-running?!
            engine-msg-queue   set-engine-msg-queue!
            engine-queue-mutex
            engine-msg-bell
            engine-stop-ch
            engine-click-regions  set-engine-click-regions!
            engine-mouse-x     set-engine-mouse-x!
            engine-mouse-y     set-engine-mouse-y!
            engine-log-entries set-engine-log-entries!
            engine-log-cap     set-engine-log-cap!
            engine-show-log?   set-engine-show-log?!
            engine-log-height-frac set-engine-log-height-frac!
            engine-focus-chain set-engine-focus-chain!
            engine-subs
            engine-resize-channel
            engine-live-widgets set-engine-live-widgets!
            engine-widget-subs
            engine-held-keys    set-engine-held-keys!
            engine-pending-key  set-engine-pending-key!
            engine-pending-action set-engine-pending-action!
            engine-pending-sub-id set-engine-pending-sub-id!
            engine-view-cache))

(define-record-type <engine>
  (%make-engine backend theme keymap title mouse-mode cursor alt-screen?
                filter root running? msg-queue queue-mutex msg-bell
                stop-ch click-regions mouse-x mouse-y
                log-entries log-cap show-log? log-height-frac
                focus-chain subs resize-channel
                live-widgets widget-subs
                held-keys pending-key pending-action pending-sub-id
                view-cache)
  engine?
  (backend     engine-backend         set-engine-backend!)
  (theme       engine-theme           set-engine-theme!)
  (keymap      engine-keymap          set-engine-keymap!)
  (title       engine-title           set-engine-title!)
  (mouse-mode  engine-mouse-mode      set-engine-mouse-mode!)
  (cursor      engine-cursor          set-engine-cursor!)
  (alt-screen? engine-alt-screen?     set-engine-alt-screen?!)
  (filter      engine-filter          set-engine-filter!)
  (root        engine-root            set-engine-root!)
  (running?    engine-running?        set-engine-running?!)
  (msg-queue   engine-msg-queue       set-engine-msg-queue!)
  (queue-mutex engine-queue-mutex)
  (msg-bell    engine-msg-bell)
  (stop-ch     engine-stop-ch)
  (click-regions engine-click-regions set-engine-click-regions!)
  (mouse-x     engine-mouse-x         set-engine-mouse-x!)
  (mouse-y     engine-mouse-y         set-engine-mouse-y!)
  (log-entries engine-log-entries     set-engine-log-entries!)
  (log-cap     engine-log-cap         set-engine-log-cap!)
  (show-log?   engine-show-log?       set-engine-show-log?!)
  (log-height-frac engine-log-height-frac set-engine-log-height-frac!)
  (focus-chain engine-focus-chain     set-engine-focus-chain!)
  (subs        engine-subs)
  (resize-channel engine-resize-channel)
  (live-widgets engine-live-widgets   set-engine-live-widgets!)
  (widget-subs  engine-widget-subs)
  ;; Chord/combo state.  HELD-KEYS is a list of (cons <key> press-time)
  ;; — the press-time lets the engine prune stale entries on legacy
  ;; terminals that don't send key-release events.  PENDING-KEY +
  ;; PENDING-ACTION + PENDING-SUB-ID let the engine defer a single-key
  ;; action while a combo is still possible: the sub-id is an after-cmd
  ;; timer that flushes the pending action if no completing key arrives
  ;; within the chord window.
  (held-keys     engine-held-keys     set-engine-held-keys!)
  (pending-key   engine-pending-key   set-engine-pending-key!)
  (pending-action engine-pending-action set-engine-pending-action!)
  (pending-sub-id engine-pending-sub-id set-engine-pending-sub-id!)
  ;; Weak-key view memo, node instance -> view tree.  Weak keys let
  ;; entries for replaced instances vanish with their nodes, so the
  ;; cache can persist across frames: unchanged widgets never re-run
  ;; their view method.
  (view-cache    engine-view-cache))

(define* (engine #:key backend theme keymap title (mouse-mode 'off)
                      (cursor 'hidden) (alt-screen? #t) filter root
                      msg-bell stop-ch
                      (resize-channel (make-channel))
                      (log-cap 200) (show-log? #t) (log-height-frac 1/5))
  "Return a fresh <engine> wired up with the supplied collaborators.
BACKEND, THEME, KEYMAP, ROOT and the message-bell / stop-channel
plumbing come from `start-engine!`; the rest are operational defaults
controlling input mode, cursor visibility, alt-screen use, log overlay
size, and the optional msg filter.  Mutable bookkeeping (queue, mouse
position, click regions, log entries, focus chain, sub table, lifecycle
trackers) starts empty."
  (%make-engine backend theme keymap title mouse-mode cursor alt-screen?
                filter root #t '() (make-mutex) msg-bell
                stop-ch '() -1 -1 '() log-cap show-log? log-height-frac
                '() (make-hash-table) resize-channel
                (make-hash-table) (make-hash-table)
                '() #f #f #f
                (make-weak-key-hash-table)))
