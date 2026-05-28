(define-module (canary input)
  #:use-module (oop goops)
  #:use-module ((canary key) #:select (<key>))
  #:use-module (canary protocol)
  #:use-module (ice-9 textual-ports)
  #:use-module ((fibers operations) #:select (perform-operation choice-operation))
  #:use-module ((fibers io-wakeup)  #:select (wait-until-port-readable-operation))
  #:use-module ((fibers timers)     #:select (sleep-operation))
  #:export (read-key-msg
            enable-input-logging
            disable-input-logging))

(define *input-log-enabled* #f)
(define *input-log-file* "/tmp/guile-canary-input-debug.log")

(define (enable-input-logging . args)
  "Enable verbose tracing of every raw input byte to a log file.
With no arguments, writes to the default path; with one argument,
treats it as the path to use.  Stamps an enable marker into the
log and returns #t."
  (when (pair? args)
    (set! *input-log-file* (car args)))
  (set! *input-log-enabled* #t)
  (let ((port (open-file *input-log-file* "a")))
    (display "=== Input logging enabled ===\n" port)
    (close-port port))
  #t)

(define (disable-input-logging)
  "Disable input tracing.  Subsequent reads are silent.  Returns #t."
  (set! *input-log-enabled* #f)
  #t)

(define (%ilog fmt . args)
  "Internal: append a formatted line to the input log when tracing
is enabled.  No-op otherwise."
  (when *input-log-enabled*
    (let ((port (open-file *input-log-file* "a")))
      (apply format port fmt args)
      (newline port)
      (close-port port))))

(define (read-key-msg)
  "Read one logical input event from the current input port.  Returns
#f when no byte is ready, the eof-object when the port has EOF'd,
otherwise a key msg.  Maps ESC into an escape-sequence parse, DEL
into 'backspace, control bytes (< 32) into ctrl-letter keys, and
other chars into bare keys."
  (let ((port (current-input-port)))
    (cond
     ((not (char-ready? port)) #f)
     (else
      (let ((char (read-char port)))
        (cond
         ((eof-object? char) char)
         ((char=? char #\escape)
          (%ilog "read-key-msg: ESC detected -> parse-escape-start")
          (parse-escape-start port))
         ((= (char->integer char) 127)
          (%ilog "read-key-msg: DEL(127) -> :backspace")
          (key 'backspace))
         ((< (char->integer char) 32)
          (let ((k (ctrl-char-to-key char)))
            (%ilog "read-key-msg: control char ~d -> ~a" (char->integer char) k)
            (cond
             ;; Named keys (Tab, Enter, Backspace) ARE the keys — the
             ;; control-range ASCII is just how the terminal sends
             ;; them.  Only real ctrl-letter combos carry 'control.
             ((symbol? k) (key k))
             (else        (key k 'control)))))
         (else
          (%ilog "read-key-msg: graphic '~a'" char)
          (key char))))))))

(define (ctrl-char-to-key char)
  "Map a control character CHAR (code < 32) to a key symbol or
letter char.  Recognises BS, TAB, LF, CR by name; everything else
maps to the corresponding lowercase letter (so C-a = ^A = code 1)."
  (let ((code (char->integer char)))
    (case code
      ((8)  'backspace)
      ((9)  'tab)
      ((10) 'enter)
      ((13) 'enter)
      (else (integer->char (+ code 96))))))

(define %escape-disambiguation-seconds 0.025)

(define (parse-escape-start port)
  "Dispatch after reading an ESC byte.  Terminals (and any byte-by-
byte transport like socat over a unix socket) emit escape sequences
in multiple writes; wait up to ~25 ms for a follow-up byte, yielding
to other fibers immediately if one arrives.  No follow-up = bare
Escape keypress."
  (cond
   ((char-ready? port)
    (let ((next (read-char port)))
      (cond
       ((eof-object? next) (key 'escape))
       (else (parse-escape-sequence next port)))))
   (else
    (perform-operation
     (choice-operation
      (wait-until-port-readable-operation port)
      (sleep-operation %escape-disambiguation-seconds)))
    (cond
     ((char-ready? port)
      (let ((next (read-char port)))
        (cond
         ((eof-object? next) (key 'escape))
         (else (parse-escape-sequence next port)))))
     (else (key 'escape))))))

(define (parse-escape-sequence char port)
  "Dispatch on the byte CHAR following ESC: '[' enters CSI, 'O'
enters SS3, an alphabetic char becomes alt-LETTER, DEL becomes
alt-backspace, anything else collapses to 'escape."
  (cond
   ((char=? char #\[)
    (%ilog "parse-escape-sequence: CSI '['")
    (parse-csi-sequence port))
   ((char=? char #\O)
    (%ilog "parse-escape-sequence: SS3 'O'")
    (parse-ss3-sequence port))
   ((char-alphabetic? char)
    (key char 'alt))
   ((= (char->integer char) 127)
    (key 'backspace 'alt))
   (else
    (%ilog "parse-escape-sequence: unknown ESC seq start '~a'" char)
    (key 'escape))))

(define (xterm-mod->mods n)
  "Decode an xterm-style modifier number (1=none, 2=shift, 3=alt,
4=shift+alt, 5=ctrl, 6=shift+ctrl, 7=alt+ctrl, 8=shift+alt+ctrl, 9..=meta).
Returns a (possibly empty) list of canonical mod symbols."
  (let ((bits (if (and (integer? n) (positive? n)) (- n 1) 0))
        (mods '()))
    (when (positive? (logand bits 1)) (set! mods (cons 'shift   mods)))
    (when (positive? (logand bits 2)) (set! mods (cons 'alt     mods)))
    (when (positive? (logand bits 4)) (set! mods (cons 'control mods)))
    (when (positive? (logand bits 8)) (set! mods (cons 'super   mods)))
    mods))

(define (tilde-key->sym n)
  "Map an ESC[N~ N value to a key symbol, or 'unknown."
  (cond
   ((memv n '(1 7))  'home)
   ((eqv? n 2)       'insert)
   ((eqv? n 3)       'delete)
   ((memv n '(4 8))  'end)
   ((eqv? n 5)       'pgup)
   ((eqv? n 6)       'pgdn)
   ((memv n '(11 12 13 14 15))
    (string->symbol (format #f "f~a" (- n 10))))
   ((memv n '(17 18 19 20 21))
    (string->symbol (format #f "f~a" (- n 11))))
   ((memv n '(23 24))
    (string->symbol (format #f "f~a" (- n 12))))
   (else 'unknown)))

(define (csi-letter->sym c)
  "Map a final CSI letter (A-Z) to a key symbol, or #f."
  (case c
    ((#\A) 'up) ((#\B) 'down) ((#\C) 'right) ((#\D) 'left)
    ((#\H) 'home) ((#\F) 'end) ((#\Z) 'backtab)
    ((#\P) 'f1) ((#\Q) 'f2) ((#\R) 'f3) ((#\S) 'f4)
    (else #f)))

(define (make-key sym mods)
  "Construct a <key> with symbol SYM and a list of modifier symbols
MODS.  Thin wrapper around `key` that takes mods as a list rather
than a rest arg."
  (apply key sym mods))

(define (read-csi-params-and-final port first-char)
  "Already consumed FIRST-CHAR (a digit). Read remaining digits, ';'
top-level separators, and ':' subparam separators until a non-numeric
non-';' non-':' terminator. Returns (values params final-char). Each
param is either a single integer (no subparams) or a list of integers
(with subparams, e.g. `1:3` becomes (1 3)).  Missing numerics become
#f.  Returns (#f #f) if the stream ends before a terminator."
  (let loop ((cur (list first-char))    ; chars of current subvalue
             (subs '())                 ; finished subvalues in current param (reversed)
             (params '()))               ; finished top-level params (reversed)
    (define (current-sub)
      (if (null? cur) #f
          (string->number (list->string cur))))
    (define (close-param)
      (let ((all (reverse (cons (current-sub) subs))))
        (if (and (pair? all) (null? (cdr all)))
            (car all)                   ; single subvalue → integer
            all)))                      ; multiple → list
    (cond
     ((not (char-ready? port))
      (values #f #f))
     (else
      (let ((c (read-char port)))
        (cond
         ((char-numeric? c)
          (loop (append cur (list c)) subs params))
         ((char=? c #\:)
          (loop '() (cons (current-sub) subs) params))
         ((char=? c #\;)
          (loop '() '() (cons (close-param) params)))
         (else
          (values (reverse (cons (close-param) params)) c))))))))

(define (parse-csi-sequence port)
  "Parse a CSI (Control Sequence Introducer) sequence after ESC[
has been consumed.  Branches on the next byte: '<' = SGR mouse, 'I'
= focus-in, 'O' = focus-out, a final letter (A-H/F/Z/P-S) = arrow
or function key, a digit starts a parameter list terminated by '~'
or a final letter.  Returns the synthesised event or 'unknown."
  (if (not (char-ready? port))
      (key 'unknown)
      (let ((ch (read-char port)))
        (%ilog "parse-csi-sequence: ch='~a' (code ~a)" ch (char->integer ch))
        (cond
         ((char=? ch #\<)         (parse-mouse-sequence port))
         ((char=? ch #\I)         (focused))
         ((char=? ch #\O)         (blurred))
         ((csi-letter->sym ch) => (lambda (sym) (key sym)))
         ((char-numeric? ch)
          (call-with-values (lambda () (read-csi-params-and-final port ch))
            (lambda (params final)
              (cond
               ((not final) (key 'unknown))
               ((eqv? final #\~)
                (let* ((n   (car params))
                       (mod (and (pair? (cdr params)) (cadr params)))
                       (sym (and n (tilde-key->sym n))))
                  (cond
                   ((not sym) (key 'unknown))
                   ((eqv? n 200) (parse-bracketed-paste port))
                   (else (make-key sym (xterm-mod->mods (or mod 1)))))))
               ((csi-letter->sym final)
                => (lambda (sym)
                     ;; ESC[1;mod{A-H,F,Z,P-S} — first param is usually 1
                     (let ((mod (and (pair? (cdr params)) (cadr params))))
                       (make-key sym (xterm-mod->mods (or mod 1))))))
               ;; ESC[8;rows;cols t — reply to `\e[18t' window-size query.
               ;; Surface as a <resize> so the engine takes the same path
               ;; as SIGWINCH-driven resizes.
               ((and (eqv? final #\t)
                     (pair? params) (eqv? (car params) 8)
                     (pair? (cdr params)) (pair? (cddr params)))
                (let ((h (cadr params))
                      (w (caddr params)))
                  (if (and h w (positive? h) (positive? w))
                      (resize w h)
                      (key 'unknown))))
               ((eqv? final #\u)
                (parse-kitty-key params))
               (else (key 'unknown))))))
         (else
          (let drain ()
            (when (char-ready? port) (read-char port) (drain)))
          (key 'unknown))))))

(define (kitty-mods->mods n)
  "Decode a kitty CSI-u modifier param N (subtract 1, then bit-test:
shift=1 alt=2 ctrl=4 super=8 hyper=16 meta=32).  Returns a list of
canonical mod symbols."
  (let ((bits (if (and (integer? n) (positive? n)) (- n 1) 0))
        (mods '()))
    (when (positive? (logand bits 1))  (set! mods (cons 'shift   mods)))
    (when (positive? (logand bits 2))  (set! mods (cons 'alt     mods)))
    (when (positive? (logand bits 4))  (set! mods (cons 'control mods)))
    (when (positive? (logand bits 8))  (set! mods (cons 'super   mods)))
    (when (positive? (logand bits 16)) (set! mods (cons 'hyper   mods)))
    (when (positive? (logand bits 32)) (set! mods (cons 'meta    mods)))
    mods))

(define (kitty-codepoint->sym cp)
  "Map a kitty CSI-u codepoint CP to a key symbol.  Plain ASCII
becomes the char itself; control codes and the kitty functional
range (57344+) map to named symbols (escape, tab, left, f1, ...).
Falls back to integer->char for anything else."
  (cond
   ((= cp 27)    'escape)
   ((= cp 13)    'enter)
   ((= cp 9)     'tab)
   ((= cp 127)   'backspace)
   ((and (>= cp 32) (< cp 127)) (integer->char cp))
   ((= cp 57344) 'escape)
   ((= cp 57345) 'enter)
   ((= cp 57346) 'tab)
   ((= cp 57347) 'backspace)
   ((= cp 57348) 'insert)
   ((= cp 57349) 'delete)
   ((= cp 57350) 'left)
   ((= cp 57351) 'right)
   ((= cp 57352) 'up)
   ((= cp 57353) 'down)
   ((= cp 57354) 'pgup)
   ((= cp 57355) 'pgdn)
   ((= cp 57356) 'home)
   ((= cp 57357) 'end)
   ((and (>= cp 57364) (<= cp 57375))
    (string->symbol (format #f "f~a" (- cp 57363))))
   (else (integer->char cp))))

(define (parse-kitty-key params)
  "Build a <key> from a kitty CSI-u parameter list PARAMS.  Shape:
`(codepoint [modifiers[:event-type[:text-codepoints]]] [text…])`.
Backend pushes flag bit 2 (report event types), so the modifier
param can be a list `(modN event-type)` where event-type is 1=press,
2=repeat, 3=release.  Sets the returned <key>'s event slot
accordingly."
  (let* ((cp        (and (pair? params)
                         (let ((p (car params)))
                           (if (pair? p) (car p) p))))
         (mod-param (and (pair? params) (pair? (cdr params)) (cadr params)))
         (mod-bits  (cond ((not mod-param) 1)
                          ((pair? mod-param) (or (car mod-param) 1))
                          (else mod-param)))
         (event-id  (cond ((and (pair? mod-param) (pair? (cdr mod-param)))
                           (cadr mod-param))
                          (else 1)))
         (event-sym (case event-id
                      ((2) 'repeat)
                      ((3) 'release)
                      (else 'press))))
    (cond
     ((not cp) (key 'unknown))
     (else
      (make <key>
        #:sym   (kitty-codepoint->sym cp)
        #:mods  (kitty-mods->mods (or mod-bits 1))
        #:event event-sym)))))

(define (parse-ss3-sequence port)
  "Parse an SS3 (Single Shift 3) sequence after ESC O has been
consumed.  Used by some terminals for arrows and home/end in
application keypad mode."
  (if (not (char-ready? port))
      (key 'unknown)
      (let ((ch (read-char port)))
        (%ilog "parse-ss3-sequence: ch='~a'" ch)
        (case ch
          ((#\A) (key 'up))
          ((#\B) (key 'down))
          ((#\C) (key 'right))
          ((#\D) (key 'left))
          ((#\H) (key 'home))
          ((#\F) (key 'end))
          (else  (key 'unknown))))))

(define (parse-mouse-sequence port)
  "Parse an SGR mouse report after ESC[< has been consumed.
Reads three semicolon-separated numeric params and a terminator (M
for press, m for release), then decodes the button byte to either a
scroll event (bit 6 set), motion event (bit 5 set, low 2 bits are
the held button or 3 for naked hover), or press/release.  Returns
a <mouse> event with 0-indexed coordinates."
  (let ((params '())
        (term #f))
    (let loop ()
      (when (and (not term) (char-ready? port))
        (let ((ch (peek-char port)))
          (cond
           ((or (char=? ch #\M) (char=? ch #\m))
            (set! term (read-char port)))
           ((char=? ch #\;)
            (read-char port)
            (loop))
           ((char-numeric? ch)
            (let read-num ((digits '()))
              (if (and (char-ready? port) (char-numeric? (peek-char port)))
                  (read-num (cons (read-char port) digits))
                  (begin
                    (set! params (cons (string->number (list->string (reverse digits))) params))
                    (loop)))))
           (else
            (read-char port)
            (loop))))))
    (if (and term (= (length params) 3))
        ;; SGR mouse coords are 1-indexed; render rects are 0-indexed.
        ;; Subtract 1 here so x/y on <mouse> messages line up with view
        ;; rectangles directly — no off-by-one at every comparison site.
        (let ((button (list-ref params 2))
              (x      (max 0 (- (list-ref params 1) 1)))
              (y      (max 0 (- (list-ref params 0) 1)))
              (action (if (char=? term #\M) 'press 'release)))
          (%ilog "parse-mouse-sequence: btn=~a x=~a y=~a action=~a" button x y action)
          (cond
           ;; wheel: bit 6 (value 64) set. low 2 bits = direction.
           ((not (zero? (logand button 64)))
            (let ((dir (logand button 1)))
              (mouse x y button (if (zero? dir) 'scroll-up 'scroll-down))))
           ;; motion: bit 5 (value 32) set. low 2 bits = which button is
           ;; held (0 left, 1 middle, 2 right) or 3 for "no button held",
           ;; i.e. naked hover. Strip the motion bit before reporting so
           ;; downstream code sees a clean button code.
           ((not (zero? (logand button 32)))
            (mouse x y (logand button 3) 'motion))
           (else (mouse x y button action))))
        (key 'unknown))))

(define (parse-bracketed-paste port)
  "Consume a bracketed-paste payload (ESC[200~ already read) up to
the ESC[201~ end marker and return a <paste> event carrying the raw
pasted string."
  (%ilog "parse-bracketed-paste: reading pasted text")
  (let ((text ""))
    (let loop ()
      (when (char-ready? port)
        (let ((ch (read-char port)))
          (cond
           ((char=? ch #\escape)
            (if (and (char-ready? port)
                    (char=? (peek-char port) #\[))
                (begin
                  (read-char port)
                  (if (and (char-ready? port)
                          (char=? (peek-char port) #\2))
                      (begin
                        (read-char port)
                        (read-char port)
                        (read-char port)
                        (read-char port)
                        (%ilog "parse-bracketed-paste: end marker found")
                        #f)
                      (begin
                        (set! text (string-append text (string #\escape #\[)))
                        (loop))))
                (begin
                  (set! text (string-append text (string #\escape)))
                  (loop))))
           (else
            (set! text (string-append text (string ch)))
            (loop))))))
    (%ilog "parse-bracketed-paste: got ~d chars" (string-length text))
    (paste text)))
