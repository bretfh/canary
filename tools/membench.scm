;;; membench.scm — allocation and heap profile of the engine core.
;;;
;;; Run: make bench-mem   (or: guile -L . tools/membench.scm)
;;;
;;; Drives a boot-menu-shaped app headless through the real engine
;;; paths at the rg34xxsp panel geometry (90x30) and reports bytes
;;; allocated, wall time, and GC runs per operation, using
;;; gc-stats deltas.  Frames render through the production ANSI
;;; backend into a void port, then feed back through canary's own
;;; terminal emulator so the parser side is measured too.

(use-modules (canary)
             (canary engine)
             ((canary engine-types) #:select (engine set-engine-root!
                                              engine-root engine-view-cache))
             ((canary backend-ansi) #:select (ansi-backend <ansi-backend>
                                              ansi-backend-size))
             ((canary view) #:select (with-view-cache))
             ((canary term types) #:prefix t:)
             ((canary term parser) #:prefix t:)
             (oop goops)
             (ice-9 format)
             (srfi srfi-1))

(define %cols 90)
(define %rows 30)

;; Engine internals under test; a bench reaches past the public
;; surface on purpose.
(define process-one   (@@ (canary engine) process-one))
(define cascade!      (@@ (canary engine) cascade!))
(define build-id-map  (@@ (canary engine) build-id-map))
(define make-bell-pipe (@@ (canary engine) make-bell-pipe))


;;;
;;; Boot-menu-shaped app.
;;;

(define (fake-entry n)
  (list n
        (format #f "generation ~a (guix abcdef~a)" n n)
        "Guix_image"
        (format #f "/gnu/store/~a-linux-libre-6.12.~a/Image" (make-string 32 #\k) n)
        (format #f "/gnu/store/~a-raw-initrd/initrd.cpio.gz" (make-string 32 #\i))
        '("console=tty0" "quiet" "loglevel=3")
        (format #f "/gnu/store/~a-system" (make-string 32 #\s))
        (= n 8)))

(define-component <bench-menu>
  (entries   #:init-value '() #:getter bm-entries)
  (sel       #:init-value 0   #:getter bm-sel)
  (remaining #:init-value 15  #:getter bm-remaining))

(define-class <sec> ())
(define-class <noop> ())

(define (entry-row m i e)
  (let ((sel? (= i (bm-sel m))))
    (hbox (txt (if sel? " > " "   ") #:fg (if sel? 'accent 'muted))
          (txt (format #f "gen ~a  " (car e))
               #:fg (if sel? 'accent 'muted))
          (txt (cadr e) #:fg (if sel? 'accent 'fg) #:bold sel?)
          (if (list-ref e 7) (txt "  * running" #:fg 'note) (txt "")))))

(define (details-pane e)
  (vbox (txt (format #f "generation ~a" (car e)) #:bold)
        (txt "press A to boot into this" #:fg 'muted)
        (spacer 1)
        (txt "kernel" #:fg 'muted)
        (wrap (list-ref e 3))
        (spacer 1)
        (txt "arguments" #:fg 'muted)
        (wrap (string-join (list-ref e 5) " "))))

(define-method (view (m <bench-menu>))
  (vbox
   (txt " membench — choose a system generation" #:bold)
   (txt (format #f " countdown (~as)" (bm-remaining m)) #:fg 'muted)
   (spacer 1)
   (hbox (flex (boxed (apply vbox
                             (map (lambda (e i) (entry-row m i e))
                                  (bm-entries m)
                                  (iota (length (bm-entries m)))))
                      #:title " generations ")
               #:grow 3)
         (flex (boxed (flex (details-pane
                             (list-ref (bm-entries m) (bm-sel m))))
                      #:title " details ")
               #:grow 4))))

(define-method (update (m <bench-menu>) (msg <sec>))
  (cons (update-slots m #:remaining (max 0 (- (bm-remaining m) 1))) #f))

(define-method (update (m <bench-menu>) (msg <key>))
  (case (key-sym msg)
    ((down) (cons (update-slots m #:sel (modulo (+ (bm-sel m) 1) 9)) #f))
    ((up)   (cons (update-slots m #:sel (modulo (- (bm-sel m) 1) 9)) #f))
    (else   (cons m #f))))


;;;
;;; Harness.
;;;

(define (alloc-now)
  (assq-ref (gc-stats) 'heap-total-allocated))

(define (gc-count)
  (assq-ref (gc-stats) 'gc-times))

(define (heap-now)
  (assq-ref (gc-stats) 'heap-size))

(define (rss-kb)
  (call-with-input-file "/proc/self/status"
    (lambda (port)
      (let loop ()
        (let ((line (read-line port)))
          (cond
           ((eof-object? line) #f)
           ((string-prefix? "VmRSS" line)
            (string->number (car (string-tokenize
                                  line char-set:digit))))
           (else (loop))))))))

(define (measure label n thunk)
  "Run THUNK N times; print per-run bytes allocated, microseconds,
and total GC runs triggered."
  (gc)
  (let ((a0 (alloc-now))
        (g0 (gc-count))
        (t0 (get-internal-real-time)))
    (do ((i 0 (+ i 1))) ((= i n)) (thunk))
    (let* ((bytes (/ (- (alloc-now) a0) n))
           (us    (/ (* (- (get-internal-real-time) t0) 1000000.0)
                     (* n internal-time-units-per-second)))
           (gcs   (- (gc-count) g0)))
      (format #t "~24a ~12,1f B/op ~10,1f us/op ~6d gcs/~ak~%"
              label (exact->inexact bytes) us gcs (/ n 1000)))))

(use-modules (ice-9 rdelim))

(format #t "== membench: ~ax~a, boot-menu-shaped tree ==~%" %cols %rows)
(format #t "post-load: rss=~aMB heap=~aMB~%"
        (quotient (or (rss-kb) 0) 1024)
        (quotient (heap-now) (* 1024 1024)))

(define backend (ansi-backend #:port (%make-void-port "w")))
(set! (ansi-backend-size backend) (size %cols %rows))

(define eng
  (engine #:backend backend
          #:theme default-theme
          #:keymap (keymap (bind #\q 'quit))
          #:root (update-slots (make <bench-menu>) #:entries (map fake-entry (iota 9 1)))
          #:msg-bell (make-bell-pipe)
          #:stop-ch (make-bell-pipe)))

(define (render-once)
  (with-view-cache (engine-view-cache eng)
    (lambda () (render-frame eng))))

(define (full-cycle msg)
  (with-view-cache (engine-view-cache eng)
    (lambda ()
      (process-one eng msg)
      (refresh-live-widgets! eng)
      (render-frame eng))))

;; Prime: first frame is the full paint.
(render-once)
(refresh-live-widgets! eng)

(define key-down (make <key> #:sym 'down #:mods '() #:event 'press))
(define key-up   (make <key> #:sym 'up   #:mods '() #:event 'press))

(measure "noop msg (gated)"       10000 (lambda () (cascade! eng (make <noop>))))
(measure "sec tick (rebuild)"     10000 (lambda () (cascade! eng (make <sec>))))
(measure "key press dispatch"     10000 (let ((flip #t))
                                          (lambda ()
                                            (set! flip (not flip))
                                            (process-one eng (if flip key-down key-up)))))
(measure "build-id-map"           10000 (lambda () (build-id-map (engine-root eng))))
(measure "refresh-live-widgets!"  10000 (lambda () (refresh-live-widgets! eng)))
(measure "render static frame"     2000 render-once)
(measure "full cycle (key+draw)"   2000 (let ((flip #t))
                                          (lambda ()
                                            (set! flip (not flip))
                                            (full-cycle (if flip key-down key-up)))))
(measure "engine-log!"            10000 (lambda () (engine-log! eng 'bench 'info "log line")))

;; Parser side: capture one moving frame's ANSI, replay through the
;; built-in emulator.
(define captured
  (let* ((buf  (open-output-string))
         (b2   (ansi-backend #:port buf)))
    (set! (ansi-backend-size b2) (size %cols %rows))
    (let ((eng2 (engine #:backend b2
                        #:theme default-theme
                        #:keymap (keymap)
                        #:root (update-slots (make <bench-menu>)
                                             #:entries (map fake-entry (iota 9 1)))
                        #:msg-bell (make-bell-pipe)
                        #:stop-ch (make-bell-pipe))))
      (with-view-cache (make-hash-table) (lambda () (render-frame eng2)))
      (process-one eng2 key-down)
      (let ((first-len (string-length (get-output-string buf))))
        first-len                                        ;ignore
        (with-view-cache (make-hash-table) (lambda () (render-frame eng2)))
        (get-output-string buf)))))

(define emu (t:make-term #:width %cols #:height %rows))
(format #t "frame sizes: full=~aB diff=~aB~%"
        (string-length captured) "(see above)")
(measure "emulator: feed diff"     2000
         (lambda () (t:term-process-output! emu captured)))

(gc)
(format #t "steady state: rss=~aMB heap=~aMB after ~a~%"
        (quotient (or (rss-kb) 0) 1024)
        (quotient (heap-now) (* 1024 1024))
        "all benches")
