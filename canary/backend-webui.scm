(define-module (canary backend-webui)
  #:use-module (canary backend)
  #:use-module (canary draw)
  #:use-module ((canary protocol) #:select (<size> size size? size-width
                                            size-height
                                            <mouse> mouse
                                            <resize> resize
                                            <paste> paste))
  #:use-module ((canary key) #:select (<key> key normalize-key))
  #:use-module ((canary backend-ansi) #:select (render-cmds-to-term!))
  #:use-module ((canary engine-types) #:select (engine-click-regions))
  #:use-module ((canary draw) #:select (clickable-cmd? clickable-col
                                        clickable-row clickable-w
                                        clickable-h))
  #:use-module ((canary draw) #:select (image-cmd? image-col image-row
                                        image-w image-h
                                        image-src image-src-x image-src-y
                                        image-src-w image-src-h))
  #:use-module ((canary image) #:select (image-registered? image-bytes))
  #:use-module ((canary term color) #:select (color-index->rgb))
  #:use-module (canary theme)
  #:use-module ((canary term types) #:prefix t:)
  #:use-module (webui)
  #:use-module (oop goops)
  #:use-module (rnrs bytevectors)
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module ((ice-9 ports) #:select (call-with-input-file))
  #:use-module ((ice-9 threads) #:select (call-with-new-thread join-thread))
  #:use-module (ice-9 match)
  #:use-module ((ice-9 format) #:select (format))
  #:export (<webui-backend>
            webui-backend
            webui-backend-window
            webui-backend-theme
            set-webui-backend-theme!
            webui-backend-stats
            reset-webui-backend-stats!
            webui-backend-reload!))

;;; Commentary:
;;;
;;; A canary backend that ships its cell grid to a libwebui WebView
;;; (webkit2gtk on Linux) instead of a terminal.  webui's C library
;;; handles the embedded HTTP+WebSocket server, embeds the webkit
;;; widget in-process, and points it at the local URL; this backend
;;; encodes each rendered frame as a compact binary blob and pushes
;;; it over the socket, where a small WebGL2 client paints it onto a
;;; canvas.
;;;
;;; The widget tree, layout, render pipeline, draw cmds, and diff are
;;; unchanged from the ANSI path: this backend implements only the
;;; backend protocol (init / shutdown / draw / size).  The cell grid
;;; (`<term>` from `canary/term/types.scm`) is the wire-shaped
;;; abstraction.  Webview side never sees widgets; it only paints
;;; cells.
;;;
;;; First paint avoids the WebSocket round trip: backend-init runs
;;; render-frame once and `client-html` inlines the encoded frame as a
;;; base64 JS variable that canary.js applyFrame()s the moment the
;;; module starts executing.
;;;
;;; Input flows the other way: the webview sends JSON events ({"type":
;;; "key"|"mouse"|"resize",...}) through a webui-bind callback, which
;;; this module translates into canary's protocol message types and
;;; delivers to the engine.
;;;
;;; Threading: libwebui's GTK webview requires that webui_show_wv and
;;; webui_wait both run on the same POSIX thread (it creates the
;;; GtkWindow + WebKitWebView in the calling thread and gtk_main has
;;; to be in that same thread).  backend-init spawns a dedicated
;;; thread that does both and then returns so the engine fibers can
;;; boot.
;;;
;;; LD_LIBRARY_PATH: `guix shell -m manifest.scm` sets LIBRARY_PATH
;;; but leaves LD_LIBRARY_PATH empty, so libwebui's internal
;;; dlopen("libgtk-3.so.0", RTLD_LAZY) returns NULL and the webview
;;; show silently no-ops.  %preload-webview-libs! walks LIBRARY_PATH
;;; and dynamic-links libgtk and libwebkit2gtk by absolute path before
;;; webui touches them, so the SONAME lookup later finds the cached
;;; handle.
;;;
;;; Code:


;;;
;;; Class.
;;;

(define-class <webui-backend> (<backend>)
  (engine     #:init-value #f #:accessor webui-backend-engine)
  (window     #:init-value #f #:accessor webui-backend-window)
  (size       #:init-keyword #:size
              #:init-value (size 80 24)
              #:accessor webui-backend-size-slot)
  (cur-term   #:init-value #f #:accessor webui-backend-cur-term)
  (wait-thread #:init-value #f #:accessor webui-backend-wait-thread)
  (stats-thread #:init-value #f #:accessor webui-backend-stats-thread)
  (theme      #:init-keyword #:theme
              #:init-value default-theme
              #:accessor webui-backend-theme)
  ;; Metrics: monotonic counters and cumulative timings.  Encoded
  ;; mostly in nanoseconds (internal-time-units-per-second is 1e9 on
  ;; Linux Guile); `stats' renders as ms.  Mutated only from the main
  ;; engine thread (draw) and the bounce-attached worker thread
  ;; (dispatch); collisions are tolerable for telemetry.
  (frames-sent   #:init-value 0 #:accessor wb-frames-sent)
  (bytes-out     #:init-value 0 #:accessor wb-bytes-out)
  (encode-ns     #:init-value 0 #:accessor wb-encode-ns)
  (encode-ns-max #:init-value 0 #:accessor wb-encode-ns-max)
  (send-ns       #:init-value 0 #:accessor wb-send-ns)
  (send-ns-max   #:init-value 0 #:accessor wb-send-ns-max)
  (draw-ns       #:init-value 0 #:accessor wb-draw-ns)
  (draw-ns-max   #:init-value 0 #:accessor wb-draw-ns-max)
  (inputs        #:init-value 0 #:accessor wb-inputs)
  (input-types   #:init-form (make-hash-table)
                 #:accessor wb-input-types)
  (parse-errors  #:init-value 0 #:accessor wb-parse-errors)
  (latency-ns    #:init-value 0 #:accessor wb-latency-ns)
  (latency-ns-max #:init-value 0 #:accessor wb-latency-ns-max)
  (latency-samples #:init-value 0 #:accessor wb-latency-samples)
  ;; image-ids maps a canary image symbol -> u32 wire id assigned
  ;; the first time we ship its bytes to the browser.  next-image-id
  ;; is the monotonic counter; image-bytes-sent counts the unique
  ;; uploads (telemetry).
  (image-ids       #:init-form (make-hash-table)
                   #:accessor webui-backend-image-ids)
  (next-image-id   #:init-value 1
                   #:accessor webui-backend-next-image-id)
  (image-bytes-sent #:init-value 0
                    #:accessor wb-image-bytes-sent)
  ;; Cached previous cell-region bytevector (W*H * cell-size).  Set to
  ;; the last full cells block we put on the wire; encode-frame diffs
  ;; against it to decide between a full and a delta frame.  Reset to
  ;; #f on resize / mark-dirty / connect so the next frame is full.
  (cells-cache      #:init-value #f
                    #:accessor webui-backend-cells-cache)
  (delta-frames     #:init-value 0 #:accessor wb-delta-frames)
  (delta-cells      #:init-value 0 #:accessor wb-delta-cells)
  (delta-skipped    #:init-value 0 #:accessor wb-delta-skipped)
  ;; Set in dispatch-browser-event! to monotonic internal-real-time
  ;; (ns) when the bounce delivers input; the engine's next event-loop
  ;; cycle reads it to compute queue-to-wake latency (the fiber-
  ;; scheduler delay).  Same clock as t-wake so the subtraction is
  ;; meaningful.  A separate wall-clock stamp (wb-last-input-wall-ms)
  ;; is kept for cross-process (JS round-trip) latency.
  (last-input-ns #:init-value 0 #:accessor wb-last-input-ns)
  (last-input-wall-ms #:init-value 0 #:accessor wb-last-input-wall-ms)
  ;; Engine event-loop telemetry, populated via BACKEND-RECORD-CYCLE!.
  (cycles        #:init-value 0 #:accessor wb-cycles)
  (cycle-ns      #:init-value 0 #:accessor wb-cycle-ns)
  (cycle-ns-max  #:init-value 0 #:accessor wb-cycle-ns-max)
  (drain-ns      #:init-value 0 #:accessor wb-drain-ns)
  (drain-ns-max  #:init-value 0 #:accessor wb-drain-ns-max)
  (process-ns    #:init-value 0 #:accessor wb-process-ns)
  (process-ns-max #:init-value 0 #:accessor wb-process-ns-max)
  (render-ns     #:init-value 0 #:accessor wb-render-ns)
  (render-ns-max #:init-value 0 #:accessor wb-render-ns-max)
  (queue-ns      #:init-value 0 #:accessor wb-queue-ns)
  (queue-ns-max  #:init-value 0 #:accessor wb-queue-ns-max)
  (queue-samples #:init-value 0 #:accessor wb-queue-samples))

(define* (webui-backend #:key (size (size 80 24)) (theme default-theme))
  "Return a fresh <webui-backend> sized to SIZE under THEME."
  (make <webui-backend> #:size size #:theme theme))

(define (set-webui-backend-theme! b th)
  "Replace the theme on backend B with TH."
  (set! (webui-backend-theme b) th))


;;;
;;; Backend protocol implementation.
;;;

(define-method (backend-uses-stdin? (b <webui-backend>)) #f)

(define-method (backend-set-engine! (b <webui-backend>) eng)
  (set! (webui-backend-engine b) eng))

(define-method (backend-size (b <webui-backend>))
  (webui-backend-size-slot b))

(define (apply-resize! b w h)
  "Bring B's size slot, cur-term, and delta cache into agreement at WxH."
  (set! (webui-backend-size-slot b) (size w h))
  (set! (webui-backend-cells-cache b) #f)
  (let ((term (webui-backend-cur-term b)))
    (when term (t:term-resize! term w h))))

(define-method (backend-handle-resize! (b <webui-backend>) w h)
  (apply-resize! b w h))

(define-method (backend-mark-dirty! (b <webui-backend>))
  ;; Drop the diff baseline so the next encode-frame emits a full frame
  ;; regardless of how little changed.  Callers use this when downstream
  ;; (browser refresh, theme swap) needs a fresh slate.
  (set! (webui-backend-cells-cache b) #f))

(define (js-string-literal s)
  "Escape S as a JavaScript double-quoted string literal."
  (let ((out (open-output-string)))
    (display #\" out)
    (string-for-each
     (lambda (c)
       (case c
         ((#\\) (display "\\\\" out))
         ((#\") (display "\\\"" out))
         ((#\newline) (display "\\n" out))
         ((#\return)  (display "\\r" out))
         ((#\tab)     (display "\\t" out))
         (else
          (let ((cp (char->integer c)))
            (cond
             ((< cp 32) (format out "\\u~4,'0x" cp))
             (else      (display c out)))))))
     s)
    (display #\" out)
    (get-output-string out)))

(define-method (backend-handle-cmd (b <webui-backend>) eng cmd)
  ;; Engine cmds → webui-side surface state.  Anything we don't model
  ;; (alt-screen, mouse-mode, terminal cursor styles beyond what's in
  ;; the frame header) is a no-op: those concepts don't exist in the
  ;; browser-as-grid setting.
  (let ((w (webui-backend-window b)))
    (when w
      (match cmd
        (('set-title text)
         (webui-run w (string-append "document.title = "
                                     (js-string-literal (or text ""))
                                     ";")))
        ;; Browser controls cursor visibility via the frame's
        ;; cursor_style byte (0 hidden, 1 block, 2 underline, 3 bar).
        ;; A runtime ('cursor hidden) cmd reaches into the term so the
        ;; next encode-frame emits the right style; same for visible /
        ;; block / underline / bar.  No webui-run round-trip needed.
        (('cursor mode)
         (let ((term (webui-backend-cur-term b)))
           (when term
             (t:set-term-cursor-style!
              term
              (case mode
                ((hidden hide)    'hidden)
                ((visible show)   'block)
                ((bar)            'bar)
                ((underline)      'underline)
                ((block)          'block)
                (else (t:term-cursor-style term)))))))
        ;; Browser has no alt-screen / mouse-mode concept; ignored.
        (('alt-screen _)  #f)
        (('mouse-mode _)  #f)
        ;; println: surface as a log entry (visible via the log
        ;; overlay) so it's not lost.  Stitch parts via the standard
        ;; cmd interpreter shape (strings concatenated, non-strings
        ;; ~aed).
        (('println . parts)
         (let ((line (apply string-append
                            (map (lambda (p)
                                   (if (string? p) p (format #f "~a" p)))
                                 parts))))
           ((module-ref (resolve-module '(canary engine)) 'engine-log!)
            eng 'app 'info line)))
        (_ #f)))))

(define-method (backend-record-cycle! (b <webui-backend>) stats)
  ;; STATS is an alist supplied by canary/engine.scm's event-loop.
  ;; Keys: t-wake (internal-real-time at scheduler wake), drain-ns,
  ;; process-ns, render-ns, cycle-ns, msg-count, dispatched?.  We
  ;; accumulate the cycle phases plus, when an input was the trigger,
  ;; subtract its arrival timestamp from t-wake to localise the
  ;; fiber-scheduler delay (queue-to-wake ns).
  (let ((cycle (assq-ref stats 'cycle-ns))
        (drain (assq-ref stats 'drain-ns))
        (proc  (assq-ref stats 'process-ns))
        (render (assq-ref stats 'render-ns)))
    (set! (wb-cycles b) (+ 1 (wb-cycles b)))
    (set! (wb-cycle-ns b) (+ cycle (wb-cycle-ns b)))
    (when (> cycle (wb-cycle-ns-max b)) (set! (wb-cycle-ns-max b) cycle))
    (set! (wb-drain-ns b) (+ drain (wb-drain-ns b)))
    (when (> drain (wb-drain-ns-max b)) (set! (wb-drain-ns-max b) drain))
    (set! (wb-process-ns b) (+ proc (wb-process-ns b)))
    (when (> proc (wb-process-ns-max b)) (set! (wb-process-ns-max b) proc))
    (set! (wb-render-ns b) (+ render (wb-render-ns b)))
    (when (> render (wb-render-ns-max b)) (set! (wb-render-ns-max b) render)))
  ;; Queue-to-wake: dispatch stamp and engine t-wake are both
  ;; internal-real-time, so the subtraction is the actual scheduler
  ;; wakeup latency for the msg that woke this cycle.  Reset the
  ;; stamp after consuming so a no-input cycle (timer tick, etc.)
  ;; doesn't double-count.
  (let ((arrival-ns (wb-last-input-ns b))
        (t-wake     (assq-ref stats 't-wake)))
    (when (and (positive? arrival-ns) t-wake (>= t-wake arrival-ns))
      (let ((ns (- t-wake arrival-ns)))
        (when (< ns 5000000000) ; <5s sanity cap
          (set! (wb-queue-ns b) (+ ns (wb-queue-ns b)))
          (set! (wb-queue-samples b) (+ 1 (wb-queue-samples b)))
          (when (> ns (wb-queue-ns-max b))
            (set! (wb-queue-ns-max b) ns))))
      (set! (wb-last-input-ns b) 0))))


;;;
;;; Init.
;;;

;; webui's send-raw target: the JS function to call in the browser
;; with the encoded frame.
(define %frame-js-fn "canaryFrame")

;; webui's bind target: a named element id the browser calls into via
;; webui.call('input', ...) to deliver every key, mouse, and resize
;; event in a single JSON payload.
(define %input-bind-id "input")

;; Frame format magic, little-endian "GCEL" (0x4C454347).
(define %frame-magic #x4C454347)

;; Device pixels per cell on the browser side.  Must stay in sync with
;; CELL_W_DEV / CELL_H_DEV defaults in backend-webui/client/canary.js.
;; Used to translate the backend's cell-grid `#:size` into the pixel
;; window size we ask webui to open the browser at, so the engine's
;; first frame fits the window exactly.  These are device px because
;; cells are now rendered in device px (so the chosen font px equals
;; that many actual pixels on screen, locked against Wayland
;; fractional-scale drift).
(define %css-cell-w 10)
(define %css-cell-h 20)


(define (%search-library-path basename)
  "Look up BASENAME (e.g. \"libgtk-3.so.0\") on $LIBRARY_PATH and
return its absolute path or #f.  guix shell -m manifest.scm sets
LIBRARY_PATH but not LD_LIBRARY_PATH, so dlopen-by-SONAME fails for
libs that ride the manifest profile — that's why libwebui's
_webui_load_gtk_and_webkit() can't find libgtk-3.so.0."
  (let* ((env  (or (getenv "LIBRARY_PATH") ""))
         (dirs (string-split env #\:)))
    (let loop ((rest dirs))
      (cond
       ((null? rest) #f)
       (else
        (let ((cand (string-append (car rest) "/" basename)))
          (cond
           ((file-exists? cand) cand)
           (else (loop (cdr rest))))))))))

(define (%preload-webview-libs!)
  "dlopen libgtk-3 and libwebkit2gtk-4.1 with their full guix-profile
paths.  Once loaded, libwebui's `dlopen(\"libgtk-3.so.0\", RTLD_LAZY)`
inside _webui_load_gtk_and_webkit() returns the cached handle instead
of searching the (empty) LD_LIBRARY_PATH.  Without this the webview
path silently no-ops with `GTK load failed` in the libwebui debug log."
  (for-each
   (lambda (name)
     (let ((p (%search-library-path name)))
       (when p
         (false-if-exception
          (dynamic-link p)))))
   '("libgtk-3.so.0"
     "libwebkit2gtk-4.1.so.0"
     "libwebkit2gtk-4.0.so.37")))

(define-method (backend-init (b <webui-backend>))
  (let* ((sz   (webui-backend-size-slot b))
         (w    (webui-new-window))
         (term (t:make-term #:width  (size-width sz)
                            #:height (size-height sz))))
    (set! (webui-backend-window   b) w)
    (set! (webui-backend-cur-term b) term)
    ;; Pre-load GTK + WebKit2GTK so libwebui's later dlopen-by-SONAME
    ;; resolves them.  Required because `guix shell -m manifest.scm`
    ;; sets LIBRARY_PATH but leaves LD_LIBRARY_PATH empty.
    (%preload-webview-libs!)
    ;; Don't block backend-init waiting for the browser to connect;
    ;; let the engine fibers start, and serve the first frame as soon
    ;; as the connection lands.
    (webui-set-config +webui-config-show-wait-connection+ #f)
    ;; webui's default timeout closes the server if no client connects
    ;; within ~30s of show(); zero means wait forever, which is what
    ;; we want for long-running canary apps.
    (webui-set-timeout 0)
    ;; Allow more than one tab to connect so reloads and curl probes
    ;; don't kill the server; canary's input is idempotent so multi-
    ;; client semantics don't break anything at this layer.
    (webui-set-config +webui-config-multi-client+ #t)
    ;; The auth-cookie path serves a redirecting "Access Denied" page
    ;; on requests without the auth cookie, which makes the demo
    ;; fragile against curl-based probes; disable it for the dev demo.
    (webui-set-config +webui-config-use-cookies+ #f)
    ;; The webview sends every key/mouse/resize event through this one
    ;; bind, tagged by type in the JSON payload.  webui invokes the
    ;; callback from a CIVETweb worker thread; guile-webui's bounce
    ;; shim wraps the dispatch in scm_with_guile so the foreign thread
    ;; is attached to Guile for the duration of the call.
    (webui-bind w %input-bind-id
                (lambda (event)
                  (dispatch-browser-event! b event)))
    ;; Empty element id catches WEBUI_EVENT_CONNECTED / DISCONNECTED so
    ;; we can drop the cells-cache and force a full re-render on every
    ;; new connection (page reload, navigation, etc.).
    (webui-bind w ""
                (lambda (event)
                  (handle-window-event! b event)))
    ;; Run render-frame once before the HTML response goes out.  The
    ;; result rides along inline as window.__canaryInitialFrame so
    ;; canary.js paints on the very first module-eval — no WebSocket
    ;; round-trip on first paint.
    (%paint-initial-grid! b)
    ;; libwebui's Linux GTK webview path requires that webui_show_wv
    ;; AND webui_wait both run in the SAME POSIX thread (webui.c:
    ;; 13434-13453 picks the calling thread when is_gtk_main_run is
    ;; false; webui.c:3899-3913 then enters gtk_main() in webui_wait,
    ;; and gtk_main has to be in the same thread that owns the widgets).
    ;; Spawning a dedicated thread that does both lets backend-init
    ;; return so the engine fibers can boot.
    (set! (webui-backend-wait-thread b)
          (call-with-new-thread
           (lambda ()
             (catch #t
               (lambda ()
                 (webui-show-wv w (client-html b))
                 (webui-wait))
               (lambda args
                 (format (current-error-port)
                         "[canary backend-webui] webview thread error: ~s~%"
                         args)
                 (force-output (current-error-port)))))))
    ;; Telemetry: dump a one-line stats snapshot every 2s to stderr AND
    ;; to engine-log! so it surfaces on the in-grid log overlay the user
    ;; is actually looking at while they use the app.  The stderr line
    ;; remains for tooling that reads the server log directly.
    (set! (webui-backend-stats-thread b)
          (call-with-new-thread
           (lambda ()
             (let loop ((prev-key #f))
               (let ((key (catch #t
                            (lambda ()
                              (sleep 2)
                              (let* ((stats (webui-backend-stats b))
                                     (cur (list (assq-ref stats 'frames-sent)
                                                (assq-ref stats 'inputs)
                                                (assq-ref stats 'parse-errors)
                                                (assq-ref stats 'bytes-out))))
                                (cond
                                 ((equal? cur prev-key) prev-key)
                                 (else
                                  (let* ((line (format-stats-line stats))
                                         (sz   (webui-backend-size-slot b))
                                         (one-line
                                          (format #f "stats grid=~ax~a ~a"
                                                  (size-width sz) (size-height sz)
                                                  (string-map
                                                   (lambda (c)
                                                     (if (char=? c #\newline)
                                                         #\space c))
                                                   line))))
                                    (format (current-error-port)
                                            "[canary backend-webui stats] ~a~%" line)
                                    (force-output (current-error-port))
                                    (let ((eng (webui-backend-engine b)))
                                      (when eng
                                        (false-if-exception
                                         ((module-ref (resolve-module '(canary engine))
                                                      'engine-log!)
                                          eng 'webui 'info one-line))))
                                    cur)))))
                            (lambda args
                              (format (current-error-port)
                                      "stats-thread error: ~s~%" args)
                              prev-key))))
                 (loop key))))))
    (let ((port (webui-get-port w)))
      (when (positive? port)
        (format (current-error-port)
                "canary webui: http://127.0.0.1:~a/~%" port)
        (force-output (current-error-port))))))

(define (webui-backend-reload! b)
  "Push a fresh HTML+JS bundle to the connected browser.  Calls into
webui_show on the existing window, which sends a WEBUI_CMD_NAVIGATION
packet (webui.c:8954-8975); the bridge handles it by issuing
`location.replace(url)`, causing the browser to re-fetch / -evaluate
the inline canary.js without the user pressing Ctrl-Shift-R.

Use this after editing canary/backend-webui/client/canary.js (or any
client asset) when you want the running session to pick up the new
code instead of stopping and restarting the canary process."
  (let ((w (webui-backend-window b)))
    (when w (webui-show-wv w (client-html b)))))

(define-method (backend-shutdown (b <webui-backend>))
  (let ((w (webui-backend-window b)))
    (when w
      (webui-close w)
      (webui-destroy w)
      (set! (webui-backend-window b) #f)))
  ;; webui-wait returns once every window is closed, so the thread
  ;; will exit on its own once webui-destroy lands.  Pull on it just
  ;; long enough to be sure the C side is drained before returning.
  (let ((t (webui-backend-wait-thread b)))
    (when t
      (webui-exit)
      (catch #t (lambda () (join-thread t 2)) (lambda _ #f))
      (set! (webui-backend-wait-thread b) #f))))


;;;
;;; Draw: term grid → binary frame → webui_send_raw.
;;;

(define (%mono-ns)
  ;; internal-time-units-per-second is 1e9 on the systems we care
  ;; about, so this is effectively a ns counter.  Cached at module
  ;; load to avoid the multiply per call.
  (get-internal-real-time))

(define (ensure-image-uploaded! b sym)
  "Return the wire id for canary image symbol SYM, uploading its
bytes to the browser via webui-send-raw if it hasn't been seen yet.
#f when SYM isn't a registered image."
  (and (image-registered? sym)
       (let* ((tbl    (webui-backend-image-ids b))
              (cached (hash-ref tbl sym)))
         (or cached
             (let* ((id    (webui-backend-next-image-id b))
                    (bytes (image-bytes sym))
                    (n     (bytevector-length bytes))
                    (blob  (make-bytevector (+ 8 n) 0)))
               (hash-set! tbl sym id)
               (set! (webui-backend-next-image-id b) (+ 1 id))
               (set! (wb-image-bytes-sent b) (+ 1 (wb-image-bytes-sent b)))
               ;; Wire shape: u32 id, u32 byte_length, raw bytes
               ;; (PNG/JPEG/etc; browser decodes via createImageBitmap).
               (bytevector-u32-set! blob 0 id (endianness little))
               (bytevector-u32-set! blob 4 n  (endianness little))
               (bytevector-copy! bytes 0 blob 8 n)
               (webui-send-raw (webui-backend-window b)
                               %image-js-fn blob)
               id)))))

(define (collect-image-placements b cmds)
  "For each <image-cmd> in CMDS, upload its bytes to the browser if
needed (cached by image symbol → u32 id) and return a list of
placements: (id col row w h src-x src-y src-w src-h).  Order
preserved so later placements paint over earlier ones."
  (let ((out '()))
    (for-each
     (lambda (cmd)
       (when (image-cmd? cmd)
         (let ((id (ensure-image-uploaded! b (image-src cmd))))
           (when id
             (set! out (cons (list id
                                   (image-col cmd) (image-row cmd)
                                   (image-w cmd) (image-h cmd)
                                   (image-src-x cmd) (image-src-y cmd)
                                   (image-src-w cmd) (image-src-h cmd))
                             out))))))
     cmds)
    (reverse out)))

(define (engine-click-rects b)
  "Pull click regions off the backend's engine, return list of
(col row w h).  The engine partitioned them out of the draw cmds in
its render-frame just before invoking backend-draw."
  (let ((eng (webui-backend-engine b)))
    (cond
     ((not eng) '())
     (else
      (let loop ((regions (engine-click-regions eng)) (out '()))
        (cond
         ((null? regions) (reverse out))
         (else
          (let ((r (car regions)))
            (cond
             ((clickable-cmd? r)
              (loop (cdr regions)
                    (cons (list (clickable-col r) (clickable-row r)
                                (clickable-w   r) (clickable-h   r))
                          out)))
             (else (loop (cdr regions) out)))))))))))

(define-method (backend-draw (b <webui-backend>) cmds)
  (let* ((term (webui-backend-cur-term b))
         (sz   (webui-backend-size-slot b))
         (th   (webui-backend-theme    b))
         (t0   (%mono-ns))
         (placements (collect-image-placements b cmds))
         (clicks     (engine-click-rects b)))
    (unless (and (= (t:term-width  term) (size-width  sz))
                 (= (t:term-height term) (size-height sz)))
      (let ((eng (webui-backend-engine b)))
        (when eng
          (false-if-exception
           ((module-ref (resolve-module '(canary engine)) 'engine-log!)
            eng 'webui 'error
            (format #f "dim mismatch: term=~ax~a slot=~ax~a"
                    (t:term-width term) (t:term-height term)
                    (size-width sz)     (size-height sz)))))))
    (render-cmds-to-term! term cmds th)
    (let* ((t1    (%mono-ns))
           (frame (encode-frame b term placements clicks))
           (t2    (%mono-ns)))
      (webui-send-raw (webui-backend-window b) %frame-js-fn frame)
      (let* ((t3        (%mono-ns))
             (encode-ns (- t2 t1))
             (send-ns   (- t3 t2))
             (draw-ns   (- t3 t0)))
        (set! (wb-frames-sent   b) (+ 1 (wb-frames-sent b)))
        (set! (wb-bytes-out     b) (+ (bytevector-length frame)
                                      (wb-bytes-out b)))
        (set! (wb-encode-ns     b) (+ encode-ns (wb-encode-ns b)))
        (when (> encode-ns (wb-encode-ns-max b))
          (set! (wb-encode-ns-max b) encode-ns))
        (set! (wb-send-ns       b) (+ send-ns (wb-send-ns b)))
        (when (> send-ns (wb-send-ns-max b))
          (set! (wb-send-ns-max b) send-ns))
        (set! (wb-draw-ns       b) (+ draw-ns (wb-draw-ns b)))
        (when (> draw-ns (wb-draw-ns-max b))
          (set! (wb-draw-ns-max b) draw-ns))))))

;; Frame layout v2 (header = 16 bytes, cells unchanged):
;;
;;   u32  magic          0x4C454347  "GCEL"
;;   u8   version        1
;;   u8   _reserved      0
;;   u16  width          cell columns
;;   u16  height         cell rows
;;   u16  cursor_col     0-based column where the cursor should paint
;;   u16  cursor_row     0-based row
;;   u8   cursor_style   0=hidden 1=block 2=underline 3=bar
;;   u8   cursor_attrs   bit 0 blink
;;
;;   for each cell, in row-major order: u32 cp, u32 fg, u32 bg, u8 attrs.

(define %frame-header-size 16)
(define %cell-size 13)
(define %delta-cell-size 17)  ; u32 index + 13-byte cell record
(define %frame-version 5)  ; v5 appends a click-region overlay
(define %click-rect-bytes 8) ; u16 col, u16 row, u16 w, u16 h

;; Frame v3 layout, after the v2 hyperlink overlay:
;;   u16 image_count
;;   image_count times:
;;     u32 image_id, u16 col, u16 row, u16 w, u16 h,
;;     u16 src_x, u16 src_y, u16 src_w, u16 src_h
;; The image bytes themselves are pushed on a separate webui_send_raw
;; channel (%image-js-fn / canaryImage) -- the client caches by id
;; so we only ship a given image once per session.
(define %image-js-fn "canaryImage")
(define %image-placement-bytes 20)  ; 4 + 2*8

(define (term-cursor-style->code style)
  (case style
    ((hidden)            0)
    ((block)             1)
    ((underline)         2)
    ((bar beam ibeam)    3)
    (else                1)))

(define (collect-hyperlinks term)
  "Walk TERM and return a list of (col row url-string) for every cell
whose face carries a hyperlink.  Sparse: cells without hyperlinks
contribute nothing.  Adjacent cells with the same URL each get their
own entry — this keeps the wire decoder dumb (the client just
overlays each (col,row,url) onto its hit-test map)."
  (let* ((w     (t:term-width  term))
         (h     (t:term-height term))
         (faces (t:term-faces  term))
         (n     (* w h))
         (out   '()))
    (do ((i 0 (+ i 1)))
        ((= i n))
      (let ((face (vector-ref faces i)))
        (when face
          (let ((url (t:face-hyperlink face)))
            (when (and url (string? url) (> (string-length url) 0))
              (let* ((col (modulo i w))
                     (row (quotient i w)))
                (set! out (cons (list col row url) out))))))))
    (reverse out)))

(define (utf8-byte-count s)
  (bytevector-length (string->utf8 s)))

(define (build-cells-bv term)
  "Encode every cell of TERM into a fresh bytevector (W*H * %cell-size).
This is the canonical cell section the frame's full path copies
verbatim; the delta path slices into it by cell index."
  (let* ((w     (t:term-width  term))
         (h     (t:term-height term))
         (cells (* w h))
         (chars (t:term-chars term))
         (faces (t:term-faces term))
         (bv    (make-bytevector (* cells %cell-size) 0)))
    (do ((i 0 (+ i 1)))
        ((= i cells) bv)
      (let* ((off  (* i %cell-size))
             (cp   (u32vector-ref chars i))
             (face (vector-ref    faces i))
             (a    (face->attrs face)))
        (bytevector-u32-set! bv off cp (endianness little))
        (bytevector-u32-set! bv (+ off 4)
                             (face-fg->rgb face) (endianness little))
        (bytevector-u32-set! bv (+ off 8)
                             (face-bg->rgb face) (endianness little))
        (bytevector-u8-set! bv (+ off 12)
                            (if (and face
                                     (let ((u (t:face-hyperlink face)))
                                       (and u (string? u))))
                                (logior a 64)
                                a))))))

(define (cells-diff-indices old new)
  "Return the list of cell indices where NEW differs from OLD (both
bytevectors with the same %cell-size stride).  Reversed insertion
order is irrelevant because the wire decoder treats each index
independently."
  (let* ((n     (bytevector-length new))
         (cells (quotient n %cell-size))
         (out   '()))
    (do ((i 0 (+ i 1)))
        ((= i cells) (reverse out))
      (let ((off (* i %cell-size)))
        (let scan ((j 0))
          (cond
           ((= j %cell-size) #f)            ; equal, no diff
           ((= (bytevector-u8-ref old (+ off j))
               (bytevector-u8-ref new (+ off j)))
            (scan (+ j 1)))
           (else
            (set! out (cons i out)))))))))

(define (encode-frame b term placements clicks)
  "Encode TERM's visible state as a v5 binary frame.

term-cursor-x / term-cursor-y are already stored 0-indexed (term-goto!
in canary/term/ops.scm subtracts 1 from the 1-indexed VT input).

Layout: 16-byte header (magic, version, frame_type, width, height,
cursor_col, cursor_row, cursor_style, cursor_attrs) then a cell
section followed by overlays: hyperlinks (v2), image placements (v3),
click regions (v5).  CLICKS is a list of (col row w h) rectangles
copied from the engine's click regions so the client can show a
pointer cursor over them.

The cell section is either a full grid copy (W*H * %cell-size
bytes) or a delta (u32 count + count entries of (u32 index,
%cell-size bytes)), selected per-frame by whichever encoding has
the smaller wire cost.  When the backend has no cells-cache (first
frame, mark-dirty, resize) we always emit a full frame and seed
the cache."
  (let* ((w     (t:term-width term))
         (h     (t:term-height term))
         (cells (* w h))
         (cx    (max 0 (t:term-cursor-x term)))
         (cy    (max 0 (t:term-cursor-y term)))
         (style (term-cursor-style->code (t:term-cursor-style term)))
         (links (collect-hyperlinks term))
         (link-utf8s (map (lambda (l) (string->utf8 (caddr l))) links))
         (link-bytes (apply + 0 (map (lambda (u)
                                       (+ 6 (bytevector-length u)))
                                     link-utf8s)))
         (n-placements (length placements))
         (n-clicks     (length clicks))
         (new-cells (build-cells-bv term))
         (full-cell-bytes (* cells %cell-size))
         (cache (webui-backend-cells-cache b))
         (deltas (and cache
                      (= (bytevector-length cache) full-cell-bytes)
                      (cells-diff-indices cache new-cells)))
         (delta-count (and deltas (length deltas)))
         (delta-bytes (and delta-count
                           (+ 4 (* delta-count %delta-cell-size))))
         (do-delta? (and delta-bytes (< delta-bytes full-cell-bytes)))
         (cell-region-size (if do-delta? delta-bytes full-cell-bytes))
         (bv (make-bytevector
              (+ %frame-header-size
                 cell-region-size
                 2 link-bytes
                 2 (* n-placements %image-placement-bytes)
                 2 (* n-clicks %click-rect-bytes))
              0)))
    ;; Header.
    (bytevector-u32-set! bv 0 %frame-magic (endianness little))
    (bytevector-u8-set!  bv 4 %frame-version)
    (bytevector-u8-set!  bv 5 (if do-delta? 1 0))
    (bytevector-u16-set! bv 6  w  (endianness little))
    (bytevector-u16-set! bv 8  h  (endianness little))
    (bytevector-u16-set! bv 10 cx (endianness little))
    (bytevector-u16-set! bv 12 cy (endianness little))
    (bytevector-u8-set!  bv 14 style)
    (bytevector-u8-set!  bv 15 0)
    ;; Cell section.
    (cond
     (do-delta?
      (bytevector-u32-set! bv %frame-header-size delta-count
                           (endianness little))
      (let loop ((ds deltas) (off (+ %frame-header-size 4)))
        (cond
         ((null? ds) #f)
         (else
          (let ((idx (car ds)))
            (bytevector-u32-set! bv off idx (endianness little))
            (bytevector-copy! new-cells (* idx %cell-size)
                              bv (+ off 4) %cell-size)
            (loop (cdr ds) (+ off %delta-cell-size))))))
      (set! (wb-delta-frames b) (+ 1 (wb-delta-frames b)))
      (set! (wb-delta-cells b)  (+ delta-count (wb-delta-cells b)))
      (set! (wb-delta-skipped b)
            (+ (- cells delta-count) (wb-delta-skipped b))))
     (else
      (bytevector-copy! new-cells 0 bv %frame-header-size full-cell-bytes)))
    ;; Hyperlink overlay.
    (let ((hl-start (+ %frame-header-size cell-region-size)))
      (bytevector-u16-set! bv hl-start (length links) (endianness little))
      (let loop ((entries links) (utf8s link-utf8s) (off (+ hl-start 2)))
        (cond
         ((null? entries)
          ;; Image-placement overlay.
          (bytevector-u16-set! bv off n-placements (endianness little))
          (let ploop ((ps placements) (poff (+ off 2)))
            (cond
             ((null? ps) #f)
             (else
              (let ((p (car ps)))
                (bytevector-u32-set! bv poff       (car p)
                                     (endianness little))
                (bytevector-u16-set! bv (+ poff  4) (cadr p)
                                     (endianness little))
                (bytevector-u16-set! bv (+ poff  6) (caddr p)
                                     (endianness little))
                (bytevector-u16-set! bv (+ poff  8) (cadddr p)
                                     (endianness little))
                (bytevector-u16-set! bv (+ poff 10) (list-ref p 4)
                                     (endianness little))
                (bytevector-u16-set! bv (+ poff 12) (list-ref p 5)
                                     (endianness little))
                (bytevector-u16-set! bv (+ poff 14) (list-ref p 6)
                                     (endianness little))
                (bytevector-u16-set! bv (+ poff 16) (list-ref p 7)
                                     (endianness little))
                (bytevector-u16-set! bv (+ poff 18) (list-ref p 8)
                                     (endianness little))
                (ploop (cdr ps) (+ poff %image-placement-bytes)))))))
         (else
          (let* ((entry (car entries))
                 (col   (car entry))
                 (row   (cadr entry))
                 (utf8  (car utf8s))
                 (ulen  (bytevector-length utf8)))
            (bytevector-u16-set! bv off       col  (endianness little))
            (bytevector-u16-set! bv (+ off 2) row  (endianness little))
            (bytevector-u16-set! bv (+ off 4) ulen (endianness little))
            (bytevector-copy!    utf8 0 bv (+ off 6) ulen)
            (loop (cdr entries) (cdr utf8s) (+ off 6 ulen)))))))
    ;; Click-region overlay (v5).  Lives at the very end of the
    ;; bytevector; we computed its offset from the total size.
    (let* ((click-start (- (bytevector-length bv)
                           2 (* n-clicks %click-rect-bytes))))
      (bytevector-u16-set! bv click-start n-clicks (endianness little))
      (let cloop ((rs clicks) (coff (+ click-start 2)))
        (cond
         ((null? rs) #f)
         (else
          (let ((r (car rs)))
            (bytevector-u16-set! bv coff       (car r)   (endianness little))
            (bytevector-u16-set! bv (+ coff 2) (cadr r)  (endianness little))
            (bytevector-u16-set! bv (+ coff 4) (caddr r) (endianness little))
            (bytevector-u16-set! bv (+ coff 6) (cadddr r) (endianness little))
            (cloop (cdr rs) (+ coff %click-rect-bytes)))))))
    ;; Update cache so the next frame can diff against the bytes the
    ;; browser is now displaying.
    (set! (webui-backend-cells-cache b) new-cells)
    bv))


;;;
;;; Face to RGB / attrs.
;;;

;; Sentinel meaning "use the browser's default" (white on black under
;; the bundled CSS).  Browser CSS picks the visible default.
(define %default-fg #xFFFFFFFF)
(define %default-bg #xFFFFFFFF)

(define (face-fg->rgb face)
  (cond
   ((not face) %default-fg)
   (else (or (and (t:face-fg face) (color->rgb (t:face-fg face)))
             %default-fg))))

(define (face-bg->rgb face)
  (cond
   ((not face) %default-bg)
   (else (or (color->rgb (t:face-bg face)) %default-bg))))

(define (color->rgb c)
  "Resolve C to a u32 with byte layout 0x00RRGGBB, or #f if unrecognised.
Accepts:
 - #f → #f (caller falls back to the default sentinel)
 - integer 0..255 → ANSI / 256-colour palette index, resolved via
   (canary term color)'s color-index->rgb; this is what canary's SGR
   parser stores for `\\e[31m`-style codes
 - 3-element list / vector → literal (R G B) from true-colour
   (`\\e[38;2;R;G;Bm`)
 - hex string like \"#ff00aa\" → parsed direct."
  (cond
   ((not c) #f)
   ((and (integer? c) (>= c 0) (< c 256))
    (let ((rgb (color-index->rgb c)))
      (and rgb
           (+ (* 256 256 (vector-ref rgb 0))
              (* 256       (vector-ref rgb 1))
              (vector-ref  rgb 2)))))
   ((string? c) (hex-string->rgb c))
   ((and (list? c) (= 3 (length c)))
    (+ (* 256 256 (car c)) (* 256 (cadr c)) (caddr c)))
   ((and (vector? c) (= 3 (vector-length c)))
    (+ (* 256 256 (vector-ref c 0))
       (* 256       (vector-ref c 1))
       (vector-ref  c 2)))
   (else #f)))

(define (hex-string->rgb s)
  (let* ((h (if (and (> (string-length s) 0)
                     (char=? #\# (string-ref s 0)))
                (substring s 1)
                s)))
    (and (= 6 (string-length h))
         (string->number h 16))))

(define (face->attrs face)
  "Pack FACE's boolean attributes into a single byte.

  bit 0  bold
  bit 1  italic
  bit 2  underline
  bit 3  inverse
  bit 4  crossed-out (strikethrough)
  bit 5  faint (dim)
  bit 6  hyperlink (cell carries an OSC-8 URL reference -- the URL
                   itself travels in the frame's hyperlink table)"
  (if (not face)
      0
      (logior (if (t:face-bold?    face) 1  0)
              (if (t:face-italic?  face) 2  0)
              (if (t:face-underline face) 4 0)
              (if (t:face-inverse? face) 8  0)
              (if (t:face-crossed? face) 16 0)
              (if (t:face-faint?   face) 32 0))))


;;;
;;; Input: browser JSON events → canary protocol msgs.
;;;

(define (%wall-ms)
  "Unix-epoch wall-clock millis; shared with client-side Date.now()."
  (let ((tv (gettimeofday)))
    (+ (* 1000 (car tv)) (quotient (cdr tv) 1000))))

(define (handle-window-event! b event)
  "Handle window-level webui events (connect / disconnect / etc.).
On a fresh connection we drop the diff cache and nudge the engine to
re-render so the browser sees a full frame even though backend-draw
already fired before the WebSocket came up."
  (let ((type (webui-event-type event))
        (eng  (webui-backend-engine b)))
    (format (current-error-port)
            "[canary backend-webui] window event type=~a~%" type)
    (force-output (current-error-port))
    (when eng
      (false-if-exception
       ((module-ref (resolve-module '(canary engine)) 'engine-log!)
        eng 'webui 'info
        (format #f "window event type=~a (~a)" type
                (cond
                 ((= type +webui-event-connected+) "connected")
                 ((= type +webui-event-disconnected+) "disconnected")
                 (else "other"))))))
    (cond
     ((= type +webui-event-connected+)
      (set! (webui-backend-cells-cache b) #f)
      (hash-clear! (webui-backend-image-ids b))
      (set! (webui-backend-next-image-id b) 1)
      (when eng (send-to-engine eng 'force-render)))
     ((= type +webui-event-disconnected+)
      ;; Closing the webview means the user wants the app gone.
      ;; libwebui doesn't reconnect after this — webui-wait returns,
      ;; the wait-thread exits, and join-thread later finishes — but
      ;; nothing else tells the engine to stop, so it sits in the
      ;; fiber scheduler indefinitely.  Trigger the same shutdown
      ;; path the 'quit cmd takes.
      (when eng
        ((module-ref (resolve-module '(canary engine)) 'stop-engine!)
         eng)))
     (else #f))))

(define (dispatch-browser-event! b event)
  "Read the JSON payload from EVENT, decode it, and forward the
resulting <key>, <mouse>, or <resize> message to the engine attached
to B.  Browser-side error/console traffic flows through this same
bind, tagged type=\"log\", and gets surfaced via ENGINE-LOG!."
  (let ((eng  (webui-backend-engine b))
        (json (webui-get-string event)))
    ;; Stamp the input arrival in two clocks: monotonic internal-
    ;; real-time (same clock as the engine's t-wake) for queue-to-
    ;; wake latency, plus wall-clock ms for cross-process round-trip
    ;; against the browser's Date.now().
    (set! (wb-last-input-ns b)      (get-internal-real-time))
    (set! (wb-last-input-wall-ms b) (%wall-ms))
    (when (and eng (string? json) (> (string-length json) 0))
      (let ((tag (json-field json "type")))
        (set! (wb-inputs b) (+ 1 (wb-inputs b)))
        (when tag
          (let ((tbl (wb-input-types b)))
            (hash-set! tbl tag (+ 1 (or (hash-ref tbl tag) 0)))))
        ;; Optional sent_ms (client-side Date.now() unix-epoch ms in
        ;; the JSON) → one-way latency in ns.  Client and server must
        ;; share an epoch; Date.now() and gettimeofday both speak unix
        ;; epoch, so localhost comparisons are valid to ms resolution.
        (let ((sent (json-num json "sent_ms")))
          (when (and sent (> sent 0))
            (let* ((delta-ms (- (wb-last-input-wall-ms b) sent))
                   (ns       (max 0 (* delta-ms 1000000))))
              (set! (wb-latency-ns b) (+ ns (wb-latency-ns b)))
              (set! (wb-latency-samples b) (+ 1 (wb-latency-samples b)))
              (when (> ns (wb-latency-ns-max b))
                (set! (wb-latency-ns-max b) ns)))))
        (cond
         ((not tag) (set! (wb-parse-errors b) (+ 1 (wb-parse-errors b))))
         ((string=? tag "log")
          (forward-log! eng json))
         ((string=? tag "ready")
          (set! (webui-backend-cells-cache b) #f)
          (send-to-engine eng 'force-render))
         (else
          (let ((msg (json->protocol-msg b json)))
            (cond
             (msg (send-to-engine eng msg))
             (else
              (set! (wb-parse-errors b)
                    (+ 1 (wb-parse-errors b))))))))))))

(define (send-to-engine eng msg)
  ;; Forward declaration trick: canary engine's `send` proc isn't yet
  ;; bound when this module is compiled (engine imports this one's
  ;; type via backend-ansi, but engine.scm's runtime resolution
  ;; happens lazily).  Look it up by name when actually called.
  (let ((send-proc (module-ref (resolve-module '(canary engine)) 'send)))
    (send-proc eng msg)))

(define (forward-log! eng json)
  "Pull \"level\" and \"text\" out of JSON and append a log entry to
ENG via the canonical canary log channel.  The level falls back to
'info; the source is always 'browser.  After appending, kick the
engine with a no-op tick so the log overlay actually paints the new
entry on the next frame."
  (let* ((level-str (or (json-field json "level") "info"))
         (text      (or (json-field json "text")  ""))
         (level (case (string->symbol level-str)
                  ((error fatal) 'error)
                  ((warn warning) 'warn)
                  (else 'info))))
    ((module-ref (resolve-module '(canary engine)) 'engine-log!)
     eng 'browser level text)
    ;; Mirror to stderr for external visibility during the demo /
    ;; diagnostic phase -- the in-grid log overlay is often disabled.
    (format (current-error-port)
            "[canary client log ~a] ~a~%" level text)
    (force-output (current-error-port))
    ;; Force a render: cascade! treats <tick> as a broadcast, and the
    ;; render-frame call inside event-loop happens whenever ANY msg
    ;; reports a state change.  A bare tick gives every widget a
    ;; chance to react (most ignore it) and reliably triggers the
    ;; redraw that surfaces the new log line on the cell grid.
    (send-to-engine eng ((module-ref (resolve-module '(canary protocol))
                                     'tick) 0))))

(define (json->protocol-msg b json)
  "Tiny ad-hoc parser for the small JSON shapes the browser emits.
Returns a canary protocol message or #f.  Avoids pulling in a full
JSON dependency for L1; the wire schema is closed."
  (let ((tag (json-field json "type")))
    (cond
     ((string=? tag "resize")
      ;; Just produce the msg.  All backend/term mutation happens on the
      ;; engine fiber via `backend-handle-resize!`; doing it here would
      ;; race with the engine's render path because this dispatch runs
      ;; on a libwebui worker thread (CIVETweb's WS handler).
      (let ((w (json-int json "width"))
            (h (json-int json "height")))
        (and w h (resize w h))))
     ((string=? tag "key")
      (let* ((sym-str (json-field json "sym"))
             (sym (and sym-str
                       (if (= 1 (string-length sym-str))
                           ;; Single-char keys travel as chars to match
                           ;; what canary's ANSI input loop produces;
                           ;; widgets test with (eqv? k #\+).
                           (string-ref sym-str 0)
                           (string->symbol sym-str))))
             (ev-str (json-field json "event"))
             (event (case (and ev-str (string->symbol ev-str))
                      ((release) 'release)
                      ((repeat)  'repeat)
                      ;; "press" or missing field both mean a fresh
                      ;; press.  Matches canary <key>'s default.
                      (else      'press))))
        (and sym
             ;; Build via normalize-key + override the event slot.
             ;; normalize-key handles mod canonicalisation; we set the
             ;; event after because canary's `key' constructor always
             ;; produces 'press.
             (let ((k (normalize-key (cons sym (json-mods json)))))
               (slot-set! k 'event event)
               k))))
     ((string=? tag "mouse")
      ;; canary/input.scm encodes buttons as small ints (0 left, 1
      ;; middle, 2 right, 3 no-button held for drag-less motion) and
      ;; actions as one of 'press 'release 'motion 'scroll-up
      ;; 'scroll-down.  The client sends button names and "move"; map
      ;; both onto canary's vocabulary so the same widgets fire as
      ;; under the ANSI loop.
      (let* ((x       (json-int   json "x"))
             (y       (json-int   json "y"))
             (btn-str (json-field json "button"))
             (act-str (json-field json "action"))
             (btn (case (and btn-str (string->symbol btn-str))
                    ((left)   0)
                    ((middle) 1)
                    ((right)  2)
                    ((none)   3)
                    (else     3)))
             (action (case (and act-str (string->symbol act-str))
                       ((press)        'press)
                       ((release)      'release)
                       ((move motion)  'motion)
                       ((scroll-up)    'scroll-up)
                       ((scroll-down)  'scroll-down)
                       (else #f))))
        (and x y action (mouse x y btn action))))
     ((string=? tag "paste")
      ;; Browser `paste` events ride this channel.  The text already
      ;; comes through the JSON-escape from JS, so what's in the
      ;; "text" field is the literal pasted string.
      (let ((text (json-field json "text")))
        (and text (paste text))))
     (else #f))))

;; Minimal JSON peekers: the wire shapes are flat objects with string
;; or integer values, no nesting.  Sufficient for the L2 demo without
;; pulling in a dependency.

(define (json-field json key)
  "Return the string value associated with KEY in flat-object JSON, or
#f if absent.  Matches \"KEY\":\"VALUE\" only."
  (let* ((needle (string-append "\"" key "\":\"")))
    (let ((i (string-contains json needle)))
      (and i
           (let* ((start (+ i (string-length needle)))
                  (end (string-index json #\" start)))
             (and end (substring json start end)))))))

(define (json-int json key)
  "Return the integer value associated with KEY in flat-object JSON,
or #f if absent.  Matches \"KEY\":NUMBER (no quotes)."
  (let* ((needle (string-append "\"" key "\":")))
    (let ((i (string-contains json needle)))
      (and i
           (let* ((start (+ i (string-length needle)))
                  (end (string-index json
                                     (lambda (c)
                                       (or (char=? c #\,)
                                           (char=? c #\})))
                                     start)))
             (and end
                  (string->number (substring json start end))))))))

(define (json-num json key)
  "Like JSON-INT but tolerant of floating-point literals (e.g. ms
timestamps from performance.now())."
  (json-int json key))

(define (json-mods json)
  "Return the modifier list for a key event, parsed from the JSON
\"mods\" field (a comma-separated string).  Empty list when absent."
  (let ((s (json-field json "mods")))
    (cond
     ((or (not s) (= 0 (string-length s))) '())
     (else
      (map string->symbol
           (string-split s #\,))))))

(define string-contains
  (@ (srfi srfi-13) string-contains))

(define (string-index s pred . rest)
  "string-index, with PRED either a char or a predicate, optionally
starting from REST."
  (let* ((start (if (null? rest) 0 (car rest)))
         (len (string-length s)))
    (let loop ((i start))
      (cond
       ((>= i len) #f)
       ((if (procedure? pred)
            (pred (string-ref s i))
            (char=? pred (string-ref s i)))
        i)
       (else (loop (+ i 1)))))))


;;;
;;; Stats.
;;;

(define (%mean-ns total n)
  (if (zero? n) 0 (quotient total n)))

(define (ns->ms ns)
  (exact->inexact (/ ns 1000000)))

(define (%bounce-counts)
  "Pull the bind/interface call counters out of the bounce shim
(zero pair if the gsubr isn't registered, e.g. tests)."
  (let ((m (resolve-module '(webui))))
    (cond
     ((module-variable m '%bounce-call-counts)
      => (lambda (var) ((variable-ref var))))
     (else '(0 . 0)))))

(define (webui-backend-stats b)
  "Return an alist snapshot of B's counters.  Times in ms unless
suffixed `-ns'; cumulative + max + mean for each timing channel."
  (let* ((frames (wb-frames-sent b))
         (inputs (wb-inputs b))
         (cycles (wb-cycles b))
         (bounce (%bounce-counts)))
    `((frames-sent      . ,frames)
      (bytes-out        . ,(wb-bytes-out b))
      (encode-ms-total  . ,(ns->ms (wb-encode-ns b)))
      (encode-ms-mean   . ,(ns->ms (%mean-ns (wb-encode-ns b) frames)))
      (encode-ms-max    . ,(ns->ms (wb-encode-ns-max b)))
      (send-ms-total    . ,(ns->ms (wb-send-ns b)))
      (send-ms-mean     . ,(ns->ms (%mean-ns (wb-send-ns b) frames)))
      (send-ms-max      . ,(ns->ms (wb-send-ns-max b)))
      (draw-ms-total    . ,(ns->ms (wb-draw-ns b)))
      (draw-ms-mean     . ,(ns->ms (%mean-ns (wb-draw-ns b) frames)))
      (draw-ms-max      . ,(ns->ms (wb-draw-ns-max b)))
      (inputs           . ,inputs)
      (input-types      . ,(hash-fold (lambda (k v acc) (acons k v acc))
                                      '() (wb-input-types b)))
      (parse-errors     . ,(wb-parse-errors b))
      (latency-samples  . ,(wb-latency-samples b))
      (latency-ms-mean  . ,(ns->ms (%mean-ns (wb-latency-ns b)
                                             (wb-latency-samples b))))
      (latency-ms-max   . ,(ns->ms (wb-latency-ns-max b)))
      (bounce-bind-calls . ,(if (pair? bounce) (car bounce) 0))
      (bounce-iface-calls . ,(if (pair? bounce) (cdr bounce) 0))
      (cycles          . ,cycles)
      (cycle-ms-mean   . ,(ns->ms (%mean-ns (wb-cycle-ns b) cycles)))
      (cycle-ms-max    . ,(ns->ms (wb-cycle-ns-max b)))
      (drain-ms-mean   . ,(ns->ms (%mean-ns (wb-drain-ns b) cycles)))
      (drain-ms-max    . ,(ns->ms (wb-drain-ns-max b)))
      (process-ms-mean . ,(ns->ms (%mean-ns (wb-process-ns b) cycles)))
      (process-ms-max  . ,(ns->ms (wb-process-ns-max b)))
      (render-ms-mean  . ,(ns->ms (%mean-ns (wb-render-ns b) cycles)))
      (render-ms-max   . ,(ns->ms (wb-render-ns-max b)))
      (queue-samples   . ,(wb-queue-samples b))
      (queue-ms-mean   . ,(ns->ms (%mean-ns (wb-queue-ns b)
                                            (wb-queue-samples b))))
      (queue-ms-max    . ,(ns->ms (wb-queue-ns-max b)))
      (delta-frames    . ,(wb-delta-frames b))
      (delta-cells     . ,(wb-delta-cells b))
      (delta-skipped   . ,(wb-delta-skipped b)))))

(define (reset-webui-backend-stats! b)
  "Zero every counter on B and clear the input-types histogram."
  (set! (wb-frames-sent b) 0)
  (set! (wb-bytes-out b) 0)
  (set! (wb-encode-ns b) 0)
  (set! (wb-encode-ns-max b) 0)
  (set! (wb-send-ns b) 0)
  (set! (wb-send-ns-max b) 0)
  (set! (wb-draw-ns b) 0)
  (set! (wb-draw-ns-max b) 0)
  (set! (wb-inputs b) 0)
  (set! (wb-input-types b) (make-hash-table))
  (set! (wb-parse-errors b) 0)
  (set! (wb-latency-ns b) 0)
  (set! (wb-latency-ns-max b) 0)
  (set! (wb-latency-samples b) 0))

(define (format-stats-line stats)
  (format #f
    "frames=~a (delta=~a, skipped=~a cells) inputs=~a bounce=~a parse-errs=~a bytes=~a~%  draw  ~,2f/~,2f ms  encode ~,2f/~,2f ms  send ~,2f/~,2f ms~%  cycle ~,2f/~,2f ms  drain ~,2f/~,2f ms  process ~,2f/~,2f ms  render ~,2f/~,2f ms~%  queue ~,2f/~,2f ms (n=~a)  lat ~,2f/~,2f ms (n=~a)"
    (assq-ref stats 'frames-sent)
    (assq-ref stats 'delta-frames)
    (assq-ref stats 'delta-skipped)
    (assq-ref stats 'inputs)
    (assq-ref stats 'bounce-bind-calls)
    (assq-ref stats 'parse-errors)
    (assq-ref stats 'bytes-out)
    (assq-ref stats 'draw-ms-mean) (assq-ref stats 'draw-ms-max)
    (assq-ref stats 'encode-ms-mean) (assq-ref stats 'encode-ms-max)
    (assq-ref stats 'send-ms-mean) (assq-ref stats 'send-ms-max)
    (assq-ref stats 'cycle-ms-mean) (assq-ref stats 'cycle-ms-max)
    (assq-ref stats 'drain-ms-mean) (assq-ref stats 'drain-ms-max)
    (assq-ref stats 'process-ms-mean) (assq-ref stats 'process-ms-max)
    (assq-ref stats 'render-ms-mean) (assq-ref stats 'render-ms-max)
    (assq-ref stats 'queue-ms-mean) (assq-ref stats 'queue-ms-max)
    (assq-ref stats 'queue-samples)
    (assq-ref stats 'latency-ms-mean) (assq-ref stats 'latency-ms-max)
    (assq-ref stats 'latency-samples)))


;;;
;;; HTML+JS bundle (served to the browser).
;;;

(define (%paint-initial-grid! b)
  "Run the engine's render-frame once against B so (webui-backend-cur-term b)
and (webui-backend-cells-cache b) hold the initial widget paint before
the HTML response goes out.  Fibers aren't running yet but render-frame
is pure-Scheme — it just reads the root, flattens to draw cmds, paints
into the term grid, and runs encode-frame which seeds cells-cache.
handle-window-event! clears cells-cache on WebSocket connect, so the
first wire frame the server pushes is still a full encode."
  (let ((eng (webui-backend-engine b)))
    (when eng
      (catch #t
        (lambda ()
          ((module-ref (resolve-module '(canary engine)) 'render-frame) eng))
        (lambda (key . args)
          (format (current-error-port)
                  "[canary backend-webui] initial paint failed: ~s ~s~%"
                  key args)
          (force-output (current-error-port)))))))

(define %base64-alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (%bv->base64 bv)
  "Encode BV as a base64 ASCII string (RFC 4648, padded).  Used to
inline the initial frame bytes into the served HTML so canary.js can
applyFrame() the moment its module finishes booting — no WebSocket
round-trip on first paint."
  (let* ((len  (bytevector-length bv))
         (full (quotient len 3))
         (rem  (- len (* 3 full)))
         (olen (* 4 (quotient (+ len 2) 3)))
         (out  (make-string olen #\=))
         (A    %base64-alphabet))
    (let loop ((i 0) (j 0))
      (cond
       ((< i full)
        (let* ((p  (* i 3))
               (b0 (bytevector-u8-ref bv p))
               (b1 (bytevector-u8-ref bv (+ p 1)))
               (b2 (bytevector-u8-ref bv (+ p 2))))
          (string-set! out  j        (string-ref A (ash b0 -2)))
          (string-set! out (+ j 1)   (string-ref A (logand #x3F
                                                           (logior (ash b0 4)
                                                                   (ash b1 -4)))))
          (string-set! out (+ j 2)   (string-ref A (logand #x3F
                                                           (logior (ash b1 2)
                                                                   (ash b2 -6)))))
          (string-set! out (+ j 3)   (string-ref A (logand #x3F b2)))
          (loop (+ i 1) (+ j 4))))
       ((= rem 1)
        (let ((b0 (bytevector-u8-ref bv (* i 3))))
          (string-set! out  j      (string-ref A (ash b0 -2)))
          (string-set! out (+ j 1) (string-ref A (logand #x3F (ash b0 4))))
          out))
       ((= rem 2)
        (let* ((p  (* i 3))
               (b0 (bytevector-u8-ref bv p))
               (b1 (bytevector-u8-ref bv (+ p 1))))
          (string-set! out  j      (string-ref A (ash b0 -2)))
          (string-set! out (+ j 1) (string-ref A (logand #x3F
                                                         (logior (ash b0 4)
                                                                 (ash b1 -4)))))
          (string-set! out (+ j 2) (string-ref A (logand #x3F (ash b1 2))))
          out))
       (else out)))))

(define (%initial-frame-base64 b)
  "Encode (webui-backend-cells-cache b) as a v5 frame bytevector and
base64 it.  Returns the empty string if no cache is seeded yet — the
client will simply wait for the first WebSocket frame as before."
  (let* ((term (webui-backend-cur-term b))
         (clicks (engine-click-rects b)))
    (cond
     ((not term) "")
     (else
      ;; Run encode-frame against an empty cells-cache so the inlined
      ;; bytes are a full frame, then re-seed the cache for the next
      ;; diff encode.
      (set! (webui-backend-cells-cache b) #f)
      (let ((bv (encode-frame b term '() clicks)))
        (%bv->base64 bv))))))

(define (client-html b)
  "Return the complete HTML document that boots the browser-side
WebGL2 renderer.  Embeds the initial frame bytes inline as base64 in
a JS variable so canary.js applyFrame()s on first module run — no
WebSocket round-trip on first paint."
  (let ((frame-b64 (%initial-frame-base64 b)))
    (string-append
     "<!doctype html><html><head>"
     "<meta charset=\"utf-8\">"
     "<meta name=\"viewport\""
     " content=\"width=device-width, initial-scale=1.0,"
     " minimum-scale=1.0, maximum-scale=1.0, user-scalable=no\">"
     "<meta http-equiv=\"Cache-Control\""
     " content=\"no-store, no-cache, must-revalidate, max-age=0\">"
     "<meta http-equiv=\"Pragma\" content=\"no-cache\">"
     "<meta http-equiv=\"Expires\" content=\"0\">"
     "<title>canary</title>"
     "<style>"
     "html,body{margin:0;height:100%;background:#000;overflow:hidden;}"
     "canvas{display:block;background:#000;}"
     "</style>"
     ;; Inline stub queues plus the initial frame, set up BEFORE
     ;; webui.js loads.  webui.js is deferred so HTML parse doesn't
     ;; block on its fetch.
     "<script>"
     "window.__canaryFrameQueue=[];"
     "window.canaryFrame=function(b){window.__canaryFrameQueue.push(b);};"
     "window.__canaryImageQueue=[];"
     "window.canaryImage=function(b){window.__canaryImageQueue.push(b);};"
     "window.__canaryInitialFrame=\"" frame-b64 "\";"
     "</script>"
     "<script src=\"webui.js\" defer></script>"
     "</head><body>"
     "<canvas id=\"cv\"></canvas>"
     "<script type=\"module\">"
     (load-client-script "canary.js")
     "</script>"
     "</body></html>")))

(define (%resolve-canary-find)
  "Return canary-build's runtime embed-table accessor (%canary-find)
if it has been registered (static-shipped binary), else #f.  The
symbol is defined as a gsubr in (guile-user) by main.zig before
user Scheme runs."
  (or (false-if-exception
       (let ((v (module-variable (resolve-module '(guile-user))
                                 '%canary-find)))
         (and v (variable-ref v))))
      (false-if-exception
       (let ((v (module-variable (current-module) '%canary-find)))
         (and v (variable-ref v))))))

(define (load-client-script relname)
  "Locate canary/backend-webui/client/RELNAME and return its
contents as a string.  Looks on disk via %load-path first (dev), then
falls back to the static-binary embed table that canary-build's
runtime installs (the bytes live at site/3.0/canary/backend-webui/
client/RELNAME under the canonical embed-path layout)."
  (let* ((rel (string-append "canary/backend-webui/client/" relname))
         (disk (search-path %load-path rel)))
    (cond
     ((and disk (file-exists? disk))
      (call-with-input-file disk get-string-all))
     (else
      (let* ((find (%resolve-canary-find))
             (key (string-append "site/3.0/" rel))
             (bytes (and find (find key))))
        (cond
         ((and bytes (bytevector? bytes))
          (utf8->string bytes))
         (else
          (error "canary backend-webui: client asset not found"
                 relname))))))))
