(define-module (canary backend-native)
  #:use-module (canary backend)
  #:use-module (canary draw)
  #:use-module ((canary protocol) #:select (<size> size size? size-width
                                            size-height
                                            <mouse> mouse
                                            <resize> resize))
  #:use-module ((canary key) #:select (<key> key normalize-key))
  #:use-module ((canary backend-ansi) #:select (render-cmds-to-term!))
  #:use-module ((canary engine-types) #:select (engine-click-regions))
  #:use-module ((canary draw) #:select (clickable-cmd? clickable-col
                                        clickable-row clickable-w
                                        clickable-h))
  #:use-module (canary theme)
  #:use-module ((canary term types) #:prefix t:)
  #:use-module (oop goops)
  #:use-module (rnrs bytevectors)
  #:use-module (system foreign)
  #:use-module ((ice-9 threads) #:select (call-with-new-thread join-thread))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module (ice-9 match)
  #:export (<native-backend>
            native-backend))

;;; Commentary:
;;;
;;; A canary backend that opens a native window via glfw and renders
;;; the cell grid directly with OpenGL 3.3 core.  Glyphs come from
;;; freetype against three DejaVu Sans Mono weights (regular/bold/
;;; oblique) packed into a sampler2DArray atlas; the cell shader is
;;; the same shape as canary's WebGL2 client (instanced quad per cell,
;;; per-cell attribs for col/row/glyph-slot/fg/bg/attrs).
;;;
;;; All glfw/GL/FreeType work happens in a single POSIX thread spawned
;;; from backend-init via call-with-new-thread.  Glfw input callbacks
;;; on that foreign thread push POD events onto a mpsc ring and notify
;;; via an eventfd; a fiber on the main thread blocks on the eventfd,
;;; drains the ring, builds canary protocol records, and sends them
;;; into the engine.  No SCM is touched from the glfw thread, which is
;;; the foreign-thread rule.
;;;
;;; backend-draw on the engine fiber hands cell bytes to the renderer
;;; through a mutex-protected mailbox inside libcanary-native.so; the
;;; render thread wakes on glfwPostEmptyEvent and uploads + draws.
;;;
;;; Code:


;;;
;;; Library load.
;;;

(define (%search-library-path basename)
  ;; Walk a union of search paths: $GUIX_ENVIRONMENT/lib (guix shell
  ;; profile root), LIBRARY_PATH, and LD_LIBRARY_PATH.  Any one of
  ;; these may carry the .so depending on how the host invoked us.
  (let* ((env (string-append
               (or (and=> (getenv "GUIX_ENVIRONMENT")
                          (lambda (p) (string-append p "/lib"))) "")
               ":"
               (or (getenv "LIBRARY_PATH") "")
               ":"
               (or (getenv "LD_LIBRARY_PATH") ""))))
    (let loop ((dirs (string-split env #\:)))
      (cond
       ((null? dirs) #f)
       ((string=? "" (car dirs)) (loop (cdr dirs)))
       (else
        (let ((path (string-append (car dirs) "/" basename)))
          (if (file-exists? path) path (loop (cdr dirs)))))))))

(define (%has-symbol? handle name)
  (false-if-exception (dynamic-func name handle)))

(define (%find-lib basename try-names probe-symbol)
  (let ((prog (false-if-exception (dynamic-link))))
    (cond
     ((and prog (%has-symbol? prog probe-symbol)) prog)
     (else
      (or (let loop ((rest try-names))
            (cond
             ((null? rest) #f)
             (else
              (let ((h (false-if-exception (dynamic-link (car rest)))))
                (or h (loop (cdr rest)))))))
          (let ((p (%search-library-path basename)))
            (and p (false-if-exception (dynamic-link p))))
          (let ((dev (string-append
                      (dirname (current-filename))
                      "/backend-native/zig-out/lib/" basename)))
            (and (file-exists? dev)
                 (false-if-exception (dynamic-link dev))))
          prog)))))

;; libnative is resolved on first use rather than at module-load so
;; this module compiles cleanly (guild can produce backend-native.go)
;; even when libcanary-native.so isn't on the host -- canary's core
;; build doesn't ship the .so; the canary-native-backend Guix package
;; does.  First call to any FFI proc forces the lookup and caches it.
(define libnative-promise
  (delay
    (%find-lib "libcanary-native.so" '("canary-native" "libcanary-native")
               "canary_native_create")))

(define (%c name) (dynamic-func name (force libnative-promise)))


;;;
;;; FFI bindings (lazy: pointer->procedure runs on first call).
;;;

(define-syntax-rule (define-foreign name ret args c-name)
  (define name
    (let ((proc #f))
      (lambda actual-args
        (unless proc
          (set! proc (pointer->procedure ret (%c c-name) args)))
        (apply proc actual-args)))))

(define-foreign %create        '*   '()                                          "canary_native_create")
(define-foreign %destroy       void '(*)                                         "canary_native_destroy")
(define-foreign %run           void '(*)                                         "canary_native_run")
(define-foreign %stop          void '(*)                                         "canary_native_stop")
(define-foreign %eventfd       int  '(*)                                         "canary_native_eventfd")
(define-foreign %drain-eventfd void '(*)                                         "canary_native_drain_eventfd")
(define-foreign %wait-event    int  '(*)                                         "canary_native_wait_event")
(define-foreign %next-event    int  (list '* '* '* '* '* '* '* '* '* '* '*)     "canary_native_next_event")
(define-foreign %submit-frame  void (list '* '* size_t uint16 uint16 uint16 uint16 uint8 int) "canary_native_submit_frame")
(define-foreign %set-title     void '(* *)                                       "canary_native_set_title")
(define-foreign %cell-w-dev    int  '()                                          "canary_native_cell_w_dev")
(define-foreign %cell-h-dev    int  '()                                          "canary_native_cell_h_dev")


;;;
;;; Class.
;;;

(define-class <native-backend> (<backend>)
  (engine        #:init-value #f #:accessor native-backend-engine)
  (handle        #:init-value #f #:accessor native-backend-handle)
  (size          #:init-keyword #:size
                 #:init-value (size 80 24)
                 #:accessor native-backend-size-slot)
  (cur-term      #:init-value #f #:accessor native-backend-cur-term)
  (theme         #:init-keyword #:theme
                 #:init-value default-theme
                 #:accessor native-backend-theme)
  (render-thread #:init-value #f #:accessor native-backend-render-thread)
  (drain-thread  #:init-value #f #:accessor native-backend-drain-thread)
  (drain-running? #:init-value #t #:accessor native-backend-drain-running?))

(define* (native-backend #:key (size (size 80 24)) (theme default-theme))
  "Return a fresh <native-backend> sized to SIZE under THEME."
  (make <native-backend> #:size size #:theme theme))


;;;
;;; Backend protocol implementation.
;;;

(define-method (backend-uses-stdin? (b <native-backend>)) #f)

(define-method (backend-set-engine! (b <native-backend>) eng)
  (set! (native-backend-engine b) eng))

(define-method (backend-size (b <native-backend>))
  (native-backend-size-slot b))

(define (apply-resize! b w h)
  (set! (native-backend-size-slot b) (size w h))
  (let ((term (native-backend-cur-term b)))
    (when term (t:term-resize! term w h))))

(define-method (backend-handle-resize! (b <native-backend>) w h)
  (apply-resize! b w h))

(define-method (backend-mark-dirty! (b <native-backend>)) #f)

(define-method (backend-handle-cmd (b <native-backend>) eng cmd)
  (match cmd
    (('set-title text)
     (let ((h (native-backend-handle b)))
       (when h (%set-title h (string->pointer (or text ""))))))
    (('cursor mode)
     (let ((term (native-backend-cur-term b)))
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
    (('alt-screen _)  #f)
    (('mouse-mode _)  #f)
    (('println . _)   #f)
    (_ #f)))

(define-method (backend-record-cycle! (b <native-backend>) stats) #f)


;;;
;;; Input direction: glfw thread -> eventfd -> fiber -> engine.
;;;

(define (send-to-engine eng msg)
  (let ((send-proc (module-ref (resolve-module '(canary engine)) 'send)))
    (send-proc eng msg)))

(define (decode-mods byte)
  "GLFW_MOD_SHIFT=1, _CONTROL=2, _ALT=4, _SUPER=8 -> canary mod symbols."
  (let loop ((bit 0) (out '()))
    (cond
     ((= bit 4) (reverse out))
     (else
      (let ((mod (case bit
                   ((0) 'shift)
                   ((1) 'control)
                   ((2) 'alt)
                   ((3) 'meta))))
        (loop (+ bit 1)
              (if (not (zero? (logand byte (ash 1 bit))))
                  (cons mod out)
                  out)))))))

;; Subset of GLFW_KEY_* that don't produce printable characters and
;; therefore must be translated into named-key symbols (chars come
;; through char_callback instead).  Matches canary.js keySym() output.
(define %glfw-named-keys
  '((256 . escape)
    (257 . enter)
    (258 . tab)
    (259 . backspace)
    (260 . insert)
    (261 . delete)
    (262 . right)
    (263 . left)
    (264 . down)
    (265 . up)
    (266 . pageup)
    (267 . pagedown)
    (268 . home)
    (269 . end)
    (290 . f1)
    (291 . f2)
    (292 . f3)
    (293 . f4)
    (294 . f5)
    (295 . f6)
    (296 . f7)
    (297 . f8)
    (298 . f9)
    (299 . f10)
    (300 . f11)
    (301 . f12)))

(define (glfw-key-action->event action)
  (case action
    ((0) 'press)
    ((1) 'release)
    ((2) 'repeat)
    (else 'press)))

(define (build-key-event sym-int mods-byte action)
  (let ((named (assv sym-int %glfw-named-keys)))
    (and named
         (let ((k (normalize-key (cons (cdr named) (decode-mods mods-byte)))))
           (slot-set! k 'event (glfw-key-action->event action))
           k))))

(define (build-char-event codepoint)
  (let ((k (normalize-key (list (integer->char codepoint)))))
    (slot-set! k 'event 'press)
    k))

(define (drain-events! b)
  (let* ((handle (native-backend-handle b))
         (eng    (native-backend-engine b)))
    (%drain-eventfd handle)
    (let ((kind-bv     (make-bytevector 1 0))
          (sym-bv      (make-bytevector 4 0))
          (mods-bv     (make-bytevector 1 0))
          (action-bv   (make-bytevector 1 0))
          (x-bv        (make-bytevector 4 0))
          (y-bv        (make-bytevector 4 0))
          (button-bv   (make-bytevector 1 0))
          (w-bv        (make-bytevector 2 0))
          (h-bv        (make-bytevector 2 0))
          (scroll-bv   (make-bytevector 1 0)))
      (let loop ()
        (let ((got (%next-event handle
                                (bytevector->pointer kind-bv)
                                (bytevector->pointer sym-bv)
                                (bytevector->pointer mods-bv)
                                (bytevector->pointer action-bv)
                                (bytevector->pointer x-bv)
                                (bytevector->pointer y-bv)
                                (bytevector->pointer button-bv)
                                (bytevector->pointer w-bv)
                                (bytevector->pointer h-bv)
                                (bytevector->pointer scroll-bv))))
          (when (and eng (positive? got))
            (let ((kind   (bytevector-u8-ref kind-bv 0))
                  (sym    (bytevector-u32-native-ref sym-bv 0))
                  (mods   (bytevector-u8-ref mods-bv 0))
                  (action (bytevector-u8-ref action-bv 0))
                  (mx     (bytevector-s32-native-ref x-bv 0))
                  (my     (bytevector-s32-native-ref y-bv 0))
                  (btn    (bytevector-u8-ref button-bv 0))
                  (rw     (bytevector-u16-native-ref w-bv 0))
                  (rh     (bytevector-u16-native-ref h-bv 0))
                  (sdy    (bytevector-s8-ref scroll-bv 0)))
              (case kind
                ((1) ; named key (printable text takes the char path below)
                 (cond
                  ;; GLFW_KEY_SPACE produces a char event, not a named-key.
                  ;; Treat printable codes (32..126) as chars when char
                  ;; event hasn't already covered them — but the simpler
                  ;; rule: emit named-key symbols only.
                  ((< sym 256)
                   ;; Translate single Unicode codepoint to a char-keyed key.
                   (when (and (>= sym 32) (= action 0))
                     (send-to-engine eng (build-char-event sym))))
                  (else
                   (let ((k (build-key-event sym mods action)))
                     (when k (send-to-engine eng k))))))
                ((2) ; mouse
                 (let* ((cell-w (%cell-w-dev))
                        (cell-h (%cell-h-dev))
                        (cx     (quotient mx cell-w))
                        (cy     (quotient my cell-h))
                        (act    (case action
                                  ((0) 'press)
                                  ((1) 'release)
                                  ((2) 'motion)
                                  (else 'motion))))
                   (send-to-engine eng (mouse cx cy btn act))))
                ((3) ; resize: framebuffer pixels -> cell grid
                 (let* ((cell-w (%cell-w-dev))
                        (cell-h (%cell-h-dev))
                        (cols   (max 20 (quotient rw cell-w)))
                        (rows   (max 5  (quotient rh cell-h))))
                   (send-to-engine eng (resize cols rows))))
                ((5) ; scroll
                 (let* ((cell-w (%cell-w-dev))
                        (cell-h (%cell-h-dev))
                        (cx     (quotient mx cell-w))
                        (cy     (quotient my cell-h)))
                   (send-to-engine eng
                                   (mouse cx cy 3
                                          (if (positive? sdy)
                                              'scroll-up 'scroll-down)))))
                (else #f)))
            (loop)))))))

(define (start-drain-thread! b)
  "Spawn a POSIX thread that blocks on the C-side wait_event call and
dispatches input into the engine.  Mirrors webui's wait-thread shape:
the engine's fiber scheduler hasn't booted yet at backend-init time, so
we can't use spawn-fiber here.  send-to-engine is thread-safe via the
engine's queue mutex."
  (let ((handle (native-backend-handle b)))
    (call-with-new-thread
     (lambda ()
       (catch #t
         (lambda ()
           (let loop ()
             (when (and (native-backend-drain-running? b)
                        (positive? (%wait-event handle)))
               (drain-events! b)
               (loop))))
         (lambda args
           (format (current-error-port)
                   "[canary backend-native] drain thread error: ~s~%"
                   args)
           (force-output (current-error-port))))))))


;;;
;;; Output direction: cmds -> term -> wire cell bytevector -> shim.
;;;

(define %cell-size 13)
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
  (cond
   ((not c) #f)
   ((and (integer? c) (>= c 0) (< c 256))
    (let ((rgb ((module-ref (resolve-module '(canary term color))
                            'color-index->rgb) c)))
      (and rgb
           (+ (* 256 256 (vector-ref rgb 0))
              (* 256       (vector-ref rgb 1))
              (vector-ref  rgb 2)))))
   ((string? c)
    (let* ((h (if (and (> (string-length c) 0)
                       (char=? #\# (string-ref c 0)))
                  (substring c 1) c)))
      (and (= 6 (string-length h)) (string->number h 16))))
   ((and (list? c) (= 3 (length c)))
    (+ (* 256 256 (car c)) (* 256 (cadr c)) (caddr c)))
   (else #f)))

(define (face->attrs face)
  (if (not face)
      0
      (logior (if (t:face-bold?    face) 1  0)
              (if (t:face-italic?  face) 2  0)
              (if (t:face-underline face) 4 0)
              (if (t:face-inverse? face) 8  0)
              (if (t:face-crossed? face) 16 0)
              (if (t:face-faint?   face) 32 0))))

(define (build-cells-bv term)
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
        (bytevector-u8-set!  bv (+ off 12) a)))))

(define-method (backend-draw (b <native-backend>) cmds)
  (let* ((term (native-backend-cur-term b))
         (sz   (native-backend-size-slot b))
         (th   (native-backend-theme    b)))
    (render-cmds-to-term! term cmds th)
    (let* ((bv (build-cells-bv term))
           (cursor-x (max 0 (t:term-cursor-x term)))
           (cursor-y (max 0 (t:term-cursor-y term)))
           (style    (case (t:term-cursor-style term)
                       ((hidden)         0)
                       ((block)          1)
                       ((underline)      2)
                       ((bar beam ibeam) 3)
                       (else             1))))
      (%submit-frame (native-backend-handle b)
                     (bytevector->pointer bv)
                     (bytevector-length bv)
                     (size-width sz)
                     (size-height sz)
                     cursor-x
                     cursor-y
                     style
                     0))))


;;;
;;; Lifecycle.
;;;

(define-method (backend-init (b <native-backend>))
  (let* ((sz   (native-backend-size-slot b))
         (term (t:make-term #:width  (size-width sz)
                            #:height (size-height sz)))
         (h    (%create)))
    (set! (native-backend-cur-term b) term)
    (set! (native-backend-handle   b) h)
    (set! (native-backend-render-thread b)
          (call-with-new-thread
           (lambda ()
             (catch #t
               (lambda () (%run h))
               (lambda args
                 (format (current-error-port)
                         "[canary backend-native] render thread error: ~s~%"
                         args)
                 (force-output (current-error-port)))))))
    (set! (native-backend-drain-thread b)
          (start-drain-thread! b))))

(define-method (backend-shutdown (b <native-backend>))
  (let ((h (native-backend-handle b)))
    (when h
      (set! (native-backend-drain-running? b) #f)
      (%stop h)
      (let ((t (native-backend-render-thread b)))
        (when t
          (catch #t (lambda () (join-thread t 2)) (lambda _ #f))
          (set! (native-backend-render-thread b) #f)))
      (let ((t (native-backend-drain-thread b)))
        (when t
          (catch #t (lambda () (join-thread t 1)) (lambda _ #f))
          (set! (native-backend-drain-thread b) #f)))
      (%destroy h)
      (set! (native-backend-handle b) #f))))
