(define-module (canary backend)
  #:use-module (oop goops)
  #:export (<backend>
            backend-init
            backend-shutdown
            backend-draw
            backend-size
            backend-uses-stdin?
            backend-set-engine!
            backend-record-cycle!
            backend-handle-cmd
            backend-mark-dirty!
            backend-handle-resize!))

(define-class <backend> ())

(define-generic backend-init)
(define-generic backend-shutdown)
(define-generic backend-draw)
(define-generic backend-size)
(define-generic backend-uses-stdin?)
(define-generic backend-set-engine!)

;; Called from engine.scm at the tail of each event-loop iteration so
;; instrumented backends (e.g. backend-webui's telemetry path) can
;; record per-cycle timing without the engine needing to know what to
;; expose.  STATS is an alist of (key . ns-value) entries; the engine
;; documents the keys it provides (currently 'cycle-ns and 'msg-count).
(define-generic backend-record-cycle!)

;; Engine cmds that translate to backend-specific output (set-title,
;; cursor, alt-screen, mouse-mode, println).  engine.scm dispatches
;; these to BACKEND-HANDLE-CMD instead of emitting ANSI directly; each
;; backend implements the ones that map onto its surface.  Default is
;; a no-op so a backend that ignores a cmd just doesn't override.
(define-generic backend-handle-cmd)

;; Force the next frame to redraw everything regardless of diff state.
;; ANSI uses it to invalidate the prev-term cache; the default-no-op
;; suits backends that always push a full frame.
(define-generic backend-mark-dirty!)

;; A resize msg has been confirmed and the backend should update its
;; own dimensions / term grid.  ANSI rewrites its size slot + drops the
;; diff baseline; webui resizes its <term> + size slot.
(define-generic backend-handle-resize!)

(define-method (backend-uses-stdin? (b <backend>)) #t)
(define-method (backend-set-engine! (b <backend>) eng) #f)
(define-method (backend-record-cycle! (b <backend>) stats) #f)
(define-method (backend-handle-cmd (b <backend>) eng cmd) #f)
(define-method (backend-mark-dirty! (b <backend>)) #f)
(define-method (backend-handle-resize! (b <backend>) w h) #f)
