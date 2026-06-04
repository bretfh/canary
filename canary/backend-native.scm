(define-module (canary backend-native)
  #:use-module (canary backend)
  #:use-module (canary draw)
  #:use-module ((canary protocol) #:select (<size> size size? size-width
                                            size-height
                                            <mouse> mouse
                                            <resize> resize))
  #:use-module ((canary key) #:select (<key> key normalize-key))
  #:use-module ((canary backend-ansi) #:select (render-cmds-to-term!))
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
;;; Backend that opens a native window via glfw and renders the cell
;;; grid through libcanary-native.so (an OpenGL 3.3 core renderer
;;; built from canary/backend-native/main.zig).
;;;
;;; The Scheme module owns every user-facing knob: font paths, font
;;; size, atlas geometry, default colours, cursor-style mapping, and
;;; the underline/strikethrough vertical positions.  Defaults live as
;;; %name constants below; the user overrides them via constructor
;;; kwargs.  All values flow into the renderer through a two-phase
;;; FFI configure call -- font config first (so freetype reports the
;;; derived cell dimensions), then the full runtime config -- before
;;; the render thread enters its loop.
;;;
;;; Code:


;;;
;;; Defaults.
;;;

(define %default-font-px           16)
(define %default-font-paths        '("DejaVuSansMono.ttf"
                                     "DejaVuSansMono-Bold.ttf"
                                     "DejaVuSansMono-Oblique.ttf"))
(define %default-atlas-cols        16)
(define %default-atlas-rows        16)
(define %default-atlas-oversample  2)
(define %default-layer-for-bold    1)
(define %default-layer-for-italic  2)
(define %default-fg                #xFFFFFFFF)  ; wire sentinel: no library opinion
(define %default-bg                #xFFFFFFFF)
(define %default-cursor-styles     '((hidden    . 0)
                                     (block     . 1)
                                     (underline . 2)
                                     (bar       . 3)))
(define %default-underline-y       0.86)
(define %default-strike-y-min      0.46)
(define %default-strike-y-max      0.54)

(define %font-dir-fallbacks
  '("/run/current-system/profile/share/fonts/truetype"
    "/.guix-home/profile/share/fonts/truetype"
    "/.guix-profile/share/fonts/truetype"))


;;;
;;; Library load.
;;;

(define (%search-library-path basename)
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
          prog)))))

(define libnative-promise
  (delay
    (%find-lib "libcanary-native.so" '("canary-native" "libcanary-native")
               "canary_native_create")))

(define (%c name) (dynamic-func name (force libnative-promise)))

(define-syntax-rule (define-foreign name ret args c-name)
  (define name
    (let ((proc #f))
      (lambda actual-args
        (unless proc
          (set! proc (pointer->procedure ret (%c c-name) args)))
        (apply proc actual-args)))))

(define-foreign %create            '*   '()                                     "canary_native_create")
(define-foreign %destroy           void '(*)                                    "canary_native_destroy")
(define-foreign %configure-font    int  '(* *)                                  "canary_native_configure_font")
(define-foreign %query-cell-size   int  '(* * *)                                "canary_native_query_cell_size")
(define-foreign %configure         int  '(* *)                                  "canary_native_configure")
(define-foreign %run               void '(*)                                    "canary_native_run")
(define-foreign %stop              void '(*)                                    "canary_native_stop")
(define-foreign %eventfd           int  '(*)                                    "canary_native_eventfd")
(define-foreign %wait-event        int  '(*)                                    "canary_native_wait_event")
(define-foreign %drain-eventfd     void '(*)                                    "canary_native_drain_eventfd")
(define-foreign %next-event        int  (list '* '* '* '* '* '* '* '* '* '* '*) "canary_native_next_event")
(define-foreign %submit-frame      void (list '* '* size_t uint16 uint16 uint16 uint16 uint8 int) "canary_native_submit_frame")
(define-foreign %set-title         void '(* *)                                  "canary_native_set_title")


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
  (font-px       #:init-keyword #:font-px
                 #:accessor native-backend-font-px)
  (font-paths    #:init-keyword #:font-paths
                 #:accessor native-backend-font-paths)
  (cell-w        #:init-keyword #:cell-w
                 #:accessor native-backend-cell-w)
  (cell-h        #:init-keyword #:cell-h
                 #:accessor native-backend-cell-h)
  (atlas-cols    #:init-keyword #:atlas-cols
                 #:accessor native-backend-atlas-cols)
  (atlas-rows    #:init-keyword #:atlas-rows
                 #:accessor native-backend-atlas-rows)
  (atlas-oversample #:init-keyword #:atlas-oversample
                    #:accessor native-backend-atlas-oversample)
  (layer-for-bold   #:init-keyword #:layer-for-bold
                    #:accessor native-backend-layer-for-bold)
  (layer-for-italic #:init-keyword #:layer-for-italic
                    #:accessor native-backend-layer-for-italic)
  (default-fg    #:init-keyword #:default-fg
                 #:accessor native-backend-default-fg)
  (default-bg    #:init-keyword #:default-bg
                 #:accessor native-backend-default-bg)
  (cursor-styles #:init-keyword #:cursor-styles
                 #:accessor native-backend-cursor-styles)
  (underline-y   #:init-keyword #:underline-y
                 #:accessor native-backend-underline-y)
  (strike-y-min  #:init-keyword #:strike-y-min
                 #:accessor native-backend-strike-y-min)
  (strike-y-max  #:init-keyword #:strike-y-max
                 #:accessor native-backend-strike-y-max)
  (render-thread  #:init-value #f #:accessor native-backend-render-thread)
  (drain-thread   #:init-value #f #:accessor native-backend-drain-thread)
  (drain-running? #:init-value #t #:accessor native-backend-drain-running?))

(define (%font-dir)
  "Resolve the directory that holds the TTF basenames passed in FONT-PATHS.
Walks CANARY_NATIVE_FONT_DIR first, then GUIX_ENVIRONMENT/share/fonts/truetype
(set by `guix shell'), then the user-profile fallbacks.  Returns the
first directory that contains at least one .ttf file."
  (define (candidate-from-env env-name suffix)
    (and=> (getenv env-name)
           (lambda (p) (string-append p suffix))))
  (define (any-ttf? dir)
    (and (file-exists? dir)
         (catch #t
           (lambda ()
             (let ((dh (opendir dir)))
               (let loop ()
                 (let ((e (readdir dh)))
                   (cond
                    ((eof-object? e) (closedir dh) #f)
                    ((string-suffix? ".ttf" e) (closedir dh) #t)
                    (else (loop)))))))
           (lambda _ #f))))
  (let ((env-dir (getenv "CANARY_NATIVE_FONT_DIR")))
    (cond
     ((and env-dir (any-ttf? env-dir)) env-dir)
     (else
      (let loop ((rest (append
                        (filter identity
                                (list (candidate-from-env "GUIX_ENVIRONMENT"
                                                          "/share/fonts/truetype")
                                      (candidate-from-env "HOME"
                                                          "/.guix-home/profile/share/fonts/truetype")
                                      (candidate-from-env "HOME"
                                                          "/.guix-profile/share/fonts/truetype")))
                        %font-dir-fallbacks)))
        (cond
         ((null? rest)
          (error "canary backend-native: no TTF font directory found; set CANARY_NATIVE_FONT_DIR"))
         ((any-ttf? (car rest)) (car rest))
         (else (loop (cdr rest)))))))))

(define (%resolve-font-path p)
  "Return P as an absolute path: P itself if it's already absolute,
otherwise (font-dir)/P."
  (cond
   ((and (string? p) (> (string-length p) 0) (char=? (string-ref p 0) #\/))
    p)
   (else
    (string-append (%font-dir) "/" p))))

(define* (native-backend
          #:key (size             (size 80 24))
                (theme            default-theme)
                (font-px          %default-font-px)
                (font-paths       %default-font-paths)
                (cell-w           #f)
                (cell-h           #f)
                (atlas-cols       %default-atlas-cols)
                (atlas-rows       %default-atlas-rows)
                (atlas-oversample %default-atlas-oversample)
                (layer-for-bold   %default-layer-for-bold)
                (layer-for-italic %default-layer-for-italic)
                (default-fg       %default-fg)
                (default-bg       %default-bg)
                (cursor-styles    %default-cursor-styles)
                (underline-y      %default-underline-y)
                (strike-y-min     %default-strike-y-min)
                (strike-y-max     %default-strike-y-max))
  "Return a fresh <native-backend>.  SIZE is the cell grid (a <size>
of columns by rows).  THEME is a <theme>.  FONT-PX is the requested
font size in device pixels; FONT-PATHS is a list of TTF basenames or
absolute paths whose length determines the atlas-layer count.  CELL-W
and CELL-H default to #f, meaning derive from the font's max advance
and ascender+descender at FONT-PX; pass explicit pixel counts to force
padded cells.  ATLAS-COLS and ATLAS-ROWS set the codepoint slot grid;
ATLAS-OVERSAMPLE multiplies atlas texture resolution against the cell
to keep glyphs crisp under fractional scaling.  LAYER-FOR-BOLD and
LAYER-FOR-ITALIC are integer indices into FONT-PATHS (or -1 for no
styled layer).  DEFAULT-FG and DEFAULT-BG are u32 RGB values (sentinel
#xFFFFFFFF means the renderer picks its own).  CURSOR-STYLES is an
alist mapping symbols (hidden block underline bar) to integer wire
codes.  UNDERLINE-Y, STRIKE-Y-MIN, and STRIKE-Y-MAX are vertical
fractions within the cell for the two decoration strips."
  (validate-kwargs! font-px font-paths atlas-cols atlas-rows atlas-oversample
                    layer-for-bold layer-for-italic
                    underline-y strike-y-min strike-y-max)
  (make <native-backend>
    #:size size #:theme theme
    #:font-px font-px
    #:font-paths font-paths
    #:cell-w cell-w
    #:cell-h cell-h
    #:atlas-cols atlas-cols
    #:atlas-rows atlas-rows
    #:atlas-oversample atlas-oversample
    #:layer-for-bold layer-for-bold
    #:layer-for-italic layer-for-italic
    #:default-fg default-fg
    #:default-bg default-bg
    #:cursor-styles cursor-styles
    #:underline-y underline-y
    #:strike-y-min strike-y-min
    #:strike-y-max strike-y-max))

(define (validate-kwargs! font-px paths cols rows oversample bold italic uy ymin ymax)
  (unless (and (integer? font-px) (positive? font-px))
    (error "native-backend: FONT-PX must be a positive integer" font-px))
  (unless (and (list? paths) (pair? paths))
    (error "native-backend: FONT-PATHS must be a non-empty list" paths))
  (unless (and (integer? cols) (positive? cols))
    (error "native-backend: ATLAS-COLS must be a positive integer" cols))
  (unless (and (integer? rows) (positive? rows))
    (error "native-backend: ATLAS-ROWS must be a positive integer" rows))
  (unless (and (integer? oversample) (positive? oversample))
    (error "native-backend: ATLAS-OVERSAMPLE must be a positive integer" oversample))
  (let ((n (length paths)))
    (unless (or (= bold -1) (and (<= 0 bold) (< bold n)))
      (error "native-backend: LAYER-FOR-BOLD out of range" bold))
    (unless (or (= italic -1) (and (<= 0 italic) (< italic n)))
      (error "native-backend: LAYER-FOR-ITALIC out of range" italic)))
  (for-each
   (lambda (v name)
     (unless (and (real? v) (<= 0 v) (<= v 1))
       (error name v)))
   (list uy ymin ymax)
   (list "native-backend: UNDERLINE-Y must be in [0,1]"
         "native-backend: STRIKE-Y-MIN must be in [0,1]"
         "native-backend: STRIKE-Y-MAX must be in [0,1]")))


;;;
;;; Config packing.
;;;

(define %font-config-size (+ 8 4 4))   ; pointer (u64) + n_paths (u32) + font_px (i32)
(define %native-config-size
  (+ 4 4 4               ; cell_w_dev, cell_h_dev, font_px_dev
     4 4 4 4             ; atlas_oversample, atlas_cols, atlas_rows, n_layers
     4 4                 ; default_fg u32, default_bg u32 (raw wire colours)
     4 4 4               ; underline_y, strike_y_min, strike_y_max
     4 4))               ; layer_for_bold, layer_for_italic


(define (pack-font-config paths-ptr-array n-paths font-px)
  "Pack a FontConfig extern struct: pointer-to-path-array, count, px.
The path-array bytevector is the caller's; keep it alive."
  (let ((bv (make-bytevector %font-config-size 0)))
    (bytevector-u64-native-set! bv 0
                                (pointer-address (bytevector->pointer paths-ptr-array)))
    (bytevector-u32-native-set! bv 8  n-paths)
    (bytevector-s32-native-set! bv 12 font-px)
    bv))

(define (pack-paths-array paths)
  "Pack PATHS (a list of strings) as a contiguous array of pointers
to null-terminated UTF-8 byte buffers.  Returns (paths-bv string-bvs)
where caller retains both bytevectors for the duration of the FFI
call so the pointers stay valid."
  (let* ((strs (map (lambda (s)
                      (let ((bv (string->utf8 s)))
                        (let ((with-nul (make-bytevector (+ 1 (bytevector-length bv)) 0)))
                          (bytevector-copy! bv 0 with-nul 0 (bytevector-length bv))
                          with-nul)))
                    paths))
         (n   (length paths))
         (out (make-bytevector (* 8 n) 0)))
    (let loop ((i 0) (rest strs))
      (cond
       ((null? rest) (values out strs))
       (else
        (bytevector-u64-native-set! out (* i 8)
                                    (pointer-address (bytevector->pointer (car rest))))
        (loop (+ i 1) (cdr rest)))))))

(define (pack-native-config b cell-w-dev cell-h-dev)
  (let* ((bv (make-bytevector %native-config-size 0)))
    (bytevector-s32-native-set! bv 0  cell-w-dev)
    (bytevector-s32-native-set! bv 4  cell-h-dev)
    (bytevector-s32-native-set! bv 8  (native-backend-font-px b))
    (bytevector-s32-native-set! bv 12 (native-backend-atlas-oversample b))
    (bytevector-s32-native-set! bv 16 (native-backend-atlas-cols b))
    (bytevector-s32-native-set! bv 20 (native-backend-atlas-rows b))
    (bytevector-u32-native-set! bv 24 (length (native-backend-font-paths b)))
    (bytevector-u32-native-set! bv 28 (native-backend-default-fg b))
    (bytevector-u32-native-set! bv 32 (native-backend-default-bg b))
    (bytevector-ieee-single-native-set! bv 36 (native-backend-underline-y b))
    (bytevector-ieee-single-native-set! bv 40 (native-backend-strike-y-min b))
    (bytevector-ieee-single-native-set! bv 44 (native-backend-strike-y-max b))
    (bytevector-s32-native-set! bv 48 (native-backend-layer-for-bold b))
    (bytevector-s32-native-set! bv 52 (native-backend-layer-for-italic b))
    bv))


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

(define (cursor-code b mode)
  "Translate a cursor MODE symbol to its wire code via the backend's
cursor-styles alist."
  (let ((entry (assq mode (native-backend-cursor-styles b))))
    (if entry (cdr entry) 1)))

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
;;; Input drain: render thread -> eventfd -> POSIX drain thread -> engine.
;;;

(define (send-to-engine eng msg)
  "Forward MSG to ENG's main fiber via the engine's `send' procedure,
which is thread-safe."
  (let ((send-proc (module-ref (resolve-module '(canary engine)) 'send)))
    (send-proc eng msg)))

(define (decode-mods byte)
  "Translate a GLFW modifier bitmask BYTE to a list of canary mod
symbols ('shift 'control 'alt 'meta)."
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
    (290 . f1)  (291 . f2)  (292 . f3)  (293 . f4)
    (294 . f5)  (295 . f6)  (296 . f7)  (297 . f8)
    (298 . f9)  (299 . f10) (300 . f11) (301 . f12)))

(define (build-key-event sym-int mods-byte action)
  "Build a <key> for GLFW key code SYM-INT, or #f if not recognised.
Named keys (escape, arrows, F-keys, etc.) use their symbol; modified
printable keys (Ctrl-S, Alt-A) use the lowercase character.  Repeats
arrive as fresh presses so held navigation keys (backspace, arrows)
advance the textinput each tick."
  (let ((named (assv sym-int %glfw-named-keys)))
    (cond
     (named
      (let ((k (normalize-key (cons (cdr named) (decode-mods mods-byte)))))
        (slot-set! k 'event 'press)
        k))
     ((and (>= sym-int 32) (<= sym-int 126))
      (let* ((cp  (if (and (>= sym-int 65) (<= sym-int 90))
                      (+ sym-int 32)
                      sym-int))
             (k   (normalize-key (cons (integer->char cp)
                                       (decode-mods mods-byte)))))
        (slot-set! k 'event 'press)
        k))
     (else #f))))

(define (build-char-event codepoint)
  "Build a <key> for the printable Unicode CODEPOINT."
  (let ((k (normalize-key (list (integer->char codepoint)))))
    (slot-set! k 'event 'press)
    k))

(define (drain-events! b)
  "Pump every pending input event out of the renderer's ring into the
engine.  Called by the drain thread after %wait-event signals."
  (let* ((handle (native-backend-handle b))
         (eng    (native-backend-engine b))
         (cell-w (native-backend-cell-w b))
         (cell-h (native-backend-cell-h b)))
    (%drain-eventfd handle)
    (let ((kind-bv   (make-bytevector 1 0))
          (sym-bv    (make-bytevector 4 0))
          (mods-bv   (make-bytevector 1 0))
          (action-bv (make-bytevector 1 0))
          (x-bv      (make-bytevector 4 0))
          (y-bv      (make-bytevector 4 0))
          (button-bv (make-bytevector 1 0))
          (w-bv      (make-bytevector 2 0))
          (h-bv      (make-bytevector 2 0))
          (scroll-bv (make-bytevector 1 0)))
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
                ((1)
                 (let ((k (build-key-event sym mods action)))
                   (when k (send-to-engine eng k))))
                ((7)
                 (when (>= sym 32)
                   (send-to-engine eng (build-char-event sym))))
                ((2)
                 (let* ((cx  (quotient mx cell-w))
                        (cy  (quotient my cell-h))
                        (act (case action
                               ((0) 'press)
                               ((1) 'release)
                               ((2) 'motion)
                               (else 'motion))))
                   (send-to-engine eng (mouse cx cy btn act))))
                ((3)
                 (let ((cols (max 20 (quotient rw cell-w)))
                       (rows (max 5  (quotient rh cell-h))))
                   (send-to-engine eng (resize cols rows))))
                ((5)
                 (let ((cx (quotient mx cell-w))
                       (cy (quotient my cell-h)))
                   (send-to-engine eng
                                   (mouse cx cy 3
                                          (if (positive? sdy)
                                              'scroll-up 'scroll-down)))))
                ((6)
                 ((module-ref (resolve-module '(canary engine))
                              'stop-engine!)
                  eng))
                (else #f)))
            (loop)))))))

(define (start-drain-thread! b)
  "Spawn the drain POSIX thread that blocks on the renderer's eventfd
and pushes input into the engine."
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
;;; Frame submission.
;;;

(define %wire-cell-size 13)
(define %color-default-sentinel #xFFFFFFFF)

(define (face-fg->rgb face)
  (cond
   ((not face) %color-default-sentinel)
   (else (or (and (t:face-fg face) (color->rgb (t:face-fg face)))
             %color-default-sentinel))))

(define (face-bg->rgb face)
  (cond
   ((not face) %color-default-sentinel)
   (else (or (color->rgb (t:face-bg face)) %color-default-sentinel))))

(define (color->rgb c)
  "Resolve C to a u32 with byte layout 0x00RRGGBB, or #f if unrecognised.
Accepts palette indices, hex strings (#rrggbb), 3-element lists/vectors."
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
  "Pack FACE's boolean attributes into a single byte: bit 0 bold, bit
1 italic, bit 2 underline, bit 3 inverse, bit 4 crossed, bit 5 faint,
bit 6 hyperlink."
  (if (not face)
      0
      (logior (if (t:face-bold?    face) 1  0)
              (if (t:face-italic?  face) 2  0)
              (if (t:face-underline face) 4 0)
              (if (t:face-inverse? face) 8  0)
              (if (t:face-crossed? face) 16 0)
              (if (t:face-faint?   face) 32 0))))

(define (build-cells-bv term)
  "Encode TERM's cells into a fresh bytevector of width*height *
%wire-cell-size bytes (u32 cp, u32 fg, u32 bg, u8 attrs)."
  (let* ((w     (t:term-width  term))
         (h     (t:term-height term))
         (cells (* w h))
         (chars (t:term-chars term))
         (faces (t:term-faces term))
         (bv    (make-bytevector (* cells %wire-cell-size) 0)))
    (do ((i 0 (+ i 1)))
        ((= i cells) bv)
      (let* ((off  (* i %wire-cell-size))
             (cp   (u32vector-ref chars i))
             (face (vector-ref    faces i))
             (a    (face->attrs face)))
        (bytevector-u32-set! bv off cp (endianness little))
        (bytevector-u32-set! bv (+ off 4) (face-fg->rgb face) (endianness little))
        (bytevector-u32-set! bv (+ off 8) (face-bg->rgb face) (endianness little))
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

(define (configure-renderer! b h)
  "Push the backend's config into the renderer.  Two phases: load the
fonts at the requested px so freetype can report derived cell metrics,
then send the full runtime config with the user override (or the
freetype-derived defaults)."
  (let* ((paths (map %resolve-font-path (native-backend-font-paths b)))
         (font-px (native-backend-font-px b))
         (oversample (native-backend-atlas-oversample b)))
    ;; Phase 1: font.
    (call-with-values
        (lambda () (pack-paths-array paths))
      (lambda (paths-bv strs)
        ;; Keep paths-bv and each string bv alive until the FFI call returns.
        (let* ((font-cfg (pack-font-config paths-bv (length paths)
                                           (* font-px oversample))))
          (let ((rc (%configure-font h (bytevector->pointer font-cfg))))
            (unless (zero? rc)
              (error "canary_native_configure_font failed" rc paths)))
          ;; Phase 2: query derived cell, then commit full config.
          (let* ((out-w (make-bytevector 4 0))
                 (out-h (make-bytevector 4 0))
                 (qrc (%query-cell-size h
                                        (bytevector->pointer out-w)
                                        (bytevector->pointer out-h))))
            (unless (zero? qrc)
              (error "canary_native_query_cell_size failed" qrc))
            (let* ((raw-w (bytevector-s32-native-ref out-w 0))
                   (raw-h (bytevector-s32-native-ref out-h 0))
                   ;; Ceiling-divide back to device px so the atlas cell
                   ;; (cell_w_dev * oversample) is never smaller than the
                   ;; font's reported bbox -- otherwise the lost fractional
                   ;; px lands on the deepest descenders.
                   (derived-w (max 1 (quotient (+ raw-w (- oversample 1)) oversample)))
                   (derived-h (max 1 (quotient (+ raw-h (- oversample 1)) oversample)))
                   (cell-w (or (native-backend-cell-w b) derived-w))
                   (cell-h (or (native-backend-cell-h b) derived-h)))
              (set! (native-backend-cell-w b) cell-w)
              (set! (native-backend-cell-h b) cell-h)
              (let ((native-cfg (pack-native-config b cell-w cell-h)))
                (let ((rc2 (%configure h (bytevector->pointer native-cfg))))
                  (unless (zero? rc2)
                    (error "canary_native_configure failed" rc2)))))))))))

(define-method (backend-init (b <native-backend>))
  (let* ((sz   (native-backend-size-slot b))
         (term (t:make-term #:width  (size-width sz)
                            #:height (size-height sz)))
         (h    (%create)))
    (set! (native-backend-cur-term b) term)
    (set! (native-backend-handle   b) h)
    (configure-renderer! b h)
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
