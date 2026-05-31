(define-module (canary backend)
  #:use-module (oop goops)
  #:export (<backend>
            backend-init
            backend-shutdown
            backend-draw
            backend-size
            backend-uses-stdin?
            backend-set-engine!
            backend-record-cycle!))

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

(define-method (backend-uses-stdin? (b <backend>)) #t)
(define-method (backend-set-engine! (b <backend>) eng) #f)
(define-method (backend-record-cycle! (b <backend>) stats) #f)
