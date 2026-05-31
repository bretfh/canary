(define-module (canary backend-webui)
  #:use-module (canary backend)
  #:use-module (canary draw)
  #:use-module ((canary protocol) #:select (<size> size size? size-width
                                            size-height
                                            <mouse> mouse
                                            <resize> resize
                                            <paste> paste))
  #:use-module ((canary key) #:select (<key> key))
  #:use-module ((canary backend-ansi) #:select (render-cmds-to-term!))
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
            reset-webui-backend-stats!))

;;; Commentary:
;;;
;;; A canary backend that ships its cell grid to a web browser instead
;;; of a terminal.  webui's C library handles the HTTP+WebSocket
;;; server and launches the user's browser in app mode; this backend
;;; encodes each rendered frame as a compact binary blob and pushes it
;;; over the socket, where a small WebGL2 client paints it onto a
;;; canvas.
;;;
;;; The widget tree, layout, render pipeline, draw cmds, and diff are
;;; unchanged from the ANSI path: this backend implements only the
;;; backend protocol (init / shutdown / draw / size).  The cell grid
;;; (`<term>` from `canary/term/types.scm`) is the wire-shaped
;;; abstraction.  Browser-side never sees widgets; it only paints
;;; cells.
;;;
;;; Input flows the other way: the browser sends JSON events ({"type":
;;; "key"|"mouse"|"resize",...}) through a webui-bind callback, which
;;; this module translates into canary's protocol message types and
;;; delivers to the engine.
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

(define-method (backend-handle-resize! (b <webui-backend>) w h)
  (set! (webui-backend-size-slot b) (size w h))
  (let ((term (webui-backend-cur-term b)))
    (when term (t:term-resize! term w h))))

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

;; Frame format magic, little-endian "CNRY" (0x59524E43).
(define %frame-magic #x59524E43)

(define-method (backend-init (b <webui-backend>))
  (let* ((sz   (webui-backend-size-slot b))
         (w    (webui-new-window))
         (term (t:make-term #:width  (size-width sz)
                            #:height (size-height sz))))
    (set! (webui-backend-window   b) w)
    (set! (webui-backend-cur-term b) term)
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
    (webui-set-size w 960 600)
    ;; The browser sends every key/mouse/resize event through this one
    ;; bind, tagged by type in the JSON payload.  webui invokes the
    ;; callback from a CIVETweb worker thread; guile-webui's bounce
    ;; shim wraps the dispatch in scm_with_guile so the foreign thread
    ;; is attached to Guile for the duration of the call.
    (webui-bind w %input-bind-id
                (lambda (event)
                  (dispatch-browser-event! b event)))
    (webui-show w (client-html))
    ;; webui's worker threads need its main event loop running for
    ;; HTTP and WS state to stay alive; without webui-wait the server
    ;; tears down as soon as the first client connects.  Run it on a
    ;; dedicated POSIX thread so the canary engine's fibers scheduler
    ;; keeps the main thread.
    (set! (webui-backend-wait-thread b)
          (call-with-new-thread
           (lambda ()
             (catch #t
               (lambda () (webui-wait))
               (lambda args
                 (format (current-error-port)
                         "webui-wait thread error: ~s~%" args))))))
    ;; Telemetry: dump a one-line stats snapshot every 2s to stderr.
    ;; engine-log! also surfaces these in canary's log overlay; the
    ;; stderr line is for tooling reading the server log directly.
    (set! (webui-backend-stats-thread b)
          (call-with-new-thread
           (lambda ()
             (let loop ()
               (catch #t
                 (lambda ()
                   (sleep 2)
                   (let ((line (format-stats-line
                                (webui-backend-stats b))))
                     (format (current-error-port)
                             "[canary backend-webui stats] ~a~%" line)
                     (force-output (current-error-port))))
                 (lambda args
                   (format (current-error-port)
                           "stats-thread error: ~s~%" args)))
               (loop)))))
    (let ((port (webui-get-port w)))
      (when (positive? port)
        (format (current-error-port)
                "canary webui: http://127.0.0.1:~a/~%" port)
        (force-output (current-error-port))))))

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

(define-method (backend-draw (b <webui-backend>) cmds)
  (let* ((term (webui-backend-cur-term b))
         (th   (webui-backend-theme    b))
         (t0   (%mono-ns)))
    (render-cmds-to-term! term cmds th)
    (let* ((t1    (%mono-ns))
           (frame (encode-frame term))
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
;;   u32  magic          0x59524E43  "CNRY"
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
(define %frame-version 2)  ; v2 appends a hyperlink overlay after the cells

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

(define (encode-frame term)
  "Encode TERM's visible grid into the v2 binary frame the browser
canaryFrame() unpacks.  Cursor coordinates come from TERM-CURSOR-X /
TERM-CURSOR-Y (canary's term keeps them 1-indexed in the VT
convention; subtract 1 to land on the cell grid).

After the cell records (W*H * 13 bytes), a hyperlink-overlay
section: u16 link-count + link-count entries of
  u16 col, u16 row, u16 url-byte-length, url bytes (utf-8)."
  (let* ((w     (t:term-width term))
         (h     (t:term-height term))
         (cells (* w h))
         (chars (t:term-chars term))
         (faces (t:term-faces term))
         (cx    (max 0 (- (t:term-cursor-x term) 1)))
         (cy    (max 0 (- (t:term-cursor-y term) 1)))
         (style (term-cursor-style->code (t:term-cursor-style term)))
         (links (collect-hyperlinks term))
         (link-utf8s (map (lambda (l) (string->utf8 (caddr l))) links))
         (link-bytes (apply + 0 (map (lambda (u)
                                       (+ 6 (bytevector-length u)))
                                     link-utf8s)))
         (bv    (make-bytevector
                 (+ %frame-header-size
                    (* cells %cell-size)
                    2                       ; u16 link count
                    link-bytes)
                 0)))
    (bytevector-u32-set! bv 0 %frame-magic (endianness little))
    (bytevector-u8-set!  bv 4 %frame-version)
    (bytevector-u8-set!  bv 5 0)
    (bytevector-u16-set! bv 6  w  (endianness little))
    (bytevector-u16-set! bv 8  h  (endianness little))
    (bytevector-u16-set! bv 10 cx (endianness little))
    (bytevector-u16-set! bv 12 cy (endianness little))
    (bytevector-u8-set!  bv 14 style)
    (bytevector-u8-set!  bv 15 0)
    (do ((i 0 (+ i 1)))
        ((= i cells))
      (let* ((off  (+ %frame-header-size (* i %cell-size)))
             (cp   (u32vector-ref chars i))
             (face (vector-ref    faces i))
             (a    (face->attrs face)))
        (bytevector-u32-set! bv off cp (endianness little))
        (bytevector-u32-set! bv (+ off 4)
                             (face-fg->rgb face) (endianness little))
        (bytevector-u32-set! bv (+ off 8)
                             (face-bg->rgb face) (endianness little))
        ;; Bit 6 of attrs flags "this cell carries a hyperlink" so the
        ;; client can do a cheap test before consulting the overlay.
        (bytevector-u8-set! bv (+ off 12)
                            (if (and face
                                     (let ((u (t:face-hyperlink face)))
                                       (and u (string? u))))
                                (logior a 64)
                                a))))
    ;; Hyperlink table.
    (let* ((cells-end (+ %frame-header-size (* cells %cell-size)))
           (count-off cells-end))
      (bytevector-u16-set! bv count-off (length links) (endianness little))
      (let loop ((entries links) (utf8s link-utf8s) (off (+ count-off 2)))
        (cond
         ((null? entries) bv)
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
            (loop (cdr entries) (cdr utf8s) (+ off 6 ulen)))))))))


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
   (else (or (color->rgb (t:face-fg face)) %default-fg))))

(define (face-bg->rgb face)
  (cond
   ((not face) %default-bg)
   (else (or (color->rgb (t:face-bg face)) %default-bg))))

(define (color->rgb c)
  "Resolve C (a hex string like \"#ff00aa\", an (R G B) list, or #f)
to a u32 with byte layout 0x00RRGGBB.  Returns #f for unrecognised
shapes."
  (cond
   ((not c) #f)
   ((string? c) (hex-string->rgb c))
   ((and (list? c) (= 3 (length c)))
    (+ (* 256 256 (car c)) (* 256 (cadr c)) (caddr c)))
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
      (let ((w (json-int json "width"))
            (h (json-int json "height")))
        (and w h
             (begin
               (resize-backend! b w h)
               (resize w h)))))
     ((string=? tag "key")
      (let* ((sym-str (json-field json "sym"))
             (sym (and sym-str
                       (if (= 1 (string-length sym-str))
                           ;; Printable single characters travel as
                           ;; chars to match what canary's ANSI input
                           ;; loop produces; widgets test with
                           ;; (eqv? k #\+).
                           (string-ref sym-str 0)
                           (string->symbol sym-str)))))
        (and sym (apply key sym (json-mods json)))))
     ((string=? tag "mouse")
      ;; Action: 'press | 'release | 'move | 'scroll-up | 'scroll-down.
      ;; Button: 'left | 'middle | 'right | 'none (for move/scroll with
      ;; no button held).  Canary's protocol shape matches what the
      ;; ANSI input loop produces, so the same widgets (textinput,
      ;; viewport, menu) react identically.
      (let ((x      (json-int   json "x"))
            (y      (json-int   json "y"))
            (btn    (json-field json "button"))
            (action (json-field json "action")))
        (and x y btn action
             (mouse x y (string->symbol btn) (string->symbol action)))))
     ((string=? tag "paste")
      ;; Browser `paste` events ride this channel.  The text already
      ;; comes through the JSON-escape from JS, so what's in the
      ;; "text" field is the literal pasted string.
      (let ((text (json-field json "text")))
        (and text (paste text))))
     (else #f))))

(define (resize-backend! b w h)
  (let ((term (webui-backend-cur-term b)))
    (set! (webui-backend-size-slot b) (size w h))
    (when term (t:term-resize! term w h))))

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
      (queue-ms-max    . ,(ns->ms (wb-queue-ns-max b))))))

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
    "frames=~a inputs=~a bounce=~a parse-errs=~a bytes=~a~%  draw  ~,2f/~,2f ms  encode ~,2f/~,2f ms  send ~,2f/~,2f ms~%  cycle ~,2f/~,2f ms  drain ~,2f/~,2f ms  process ~,2f/~,2f ms  render ~,2f/~,2f ms~%  queue ~,2f/~,2f ms (n=~a)  lat ~,2f/~,2f ms (n=~a)"
    (assq-ref stats 'frames-sent)
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

(define (client-html)
  "Return the complete HTML document that boots the browser-side
WebGL2 renderer.  Reads its JavaScript pieces from
canary/backend-webui/client/ via the load path."
  (string-append
   "<!doctype html><html><head>"
   "<meta charset=\"utf-8\">"
   "<title>canary</title>"
   "<style>"
   "html,body{margin:0;height:100%;background:#000;overflow:hidden;}"
   "canvas{display:block;width:100vw;height:100vh;background:#000;}"
   "</style>"
   "<script src=\"webui.js\"></script>"
   "</head><body>"
   "<canvas id=\"cv\"></canvas>"
   "<script type=\"module\">"
   (load-client-script "canary.js")
   "</script>"
   "</body></html>"))

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
