(define-module (canary term modes)
  #:use-module (srfi srfi-9)
  #:export (<mode-def>
            mode-def?
            mode-def-name
            mode-def-number
            mode-def-kind
            mode-def-default
            mode-def-doc

            *modes*
            mode-def-by-name
            mode-def-by-key

            <mode-state>
            mode-state?
            make-mode-state
            mode-get
            mode-set!
            mode-save!
            mode-restore!
            mode-reset!
            mode-state-values))

;;; Commentary:
;;;
;;; Mode state for a <term>.  Replaces the prior ad-hoc boolean slots
;;; (auto-margin?, insert?, keypad?, bracketed-paste?, cursor-visible?)
;;; with a single <mode-state> over the full table of ECMA-48 / DEC /
;;; xterm modes.  Most entries are flags the parser sets but no
;;; consumer reads yet -- they're defined here so the parser can
;;; accept them and so introspection ((mode-get t 'something)) returns
;;; a sensible value.  Track B will wire input-side flags (cursor
;;; keys, mouse modes, alt-key modifiers) to byte-encoder logic.
;;;
;;; Code:

(define-record-type <mode-def>
  (%make-mode-def name number kind default doc)
  mode-def?
  (name    mode-def-name)
  (number  mode-def-number)
  (kind    mode-def-kind)
  (default mode-def-default)
  (doc     mode-def-doc))

(define (mode-def name number kind default doc)
  "Return a fresh <mode-def>.  KIND is 'ansi or 'dec-private; NUMBER
is the parameter number used by CSI Pm h / CSI Pm l (with a private
'?' prefix for DEC modes).  DEFAULT is the boolean value after RIS."
  (%make-mode-def name number kind default doc))

(define *modes*
  (list
   ;; ECMA-48 / ANSI modes.
   (mode-def 'keyboard-action 2 'ansi #f
             "KAM: disable keyboard input when set.")
   (mode-def 'insert 4 'ansi #f
             "IRM: insert vs overwrite mode for printable input.")
   (mode-def 'send-receive 12 'ansi #f
             "SRM: local echo when reset; remote when set.")
   (mode-def 'auto-newline 20 'ansi #f
             "LNM: LF performs a CR as well when set.")

   ;; DEC private modes.
   (mode-def 'cursor-keys 1 'dec-private #f
             "DECCKM: cursor keys send SS3 sequences when set.")
   (mode-def 'column-132 3 'dec-private #f
             "DECCOLM: 132-column mode when set, 80-column when reset.")
   (mode-def 'smooth-scroll 4 'dec-private #f
             "DECSCLM: smooth scrolling when set, jump scrolling when reset.")
   (mode-def 'reverse-video 5 'dec-private #f
             "DECSCNM: globally swap fg/bg when set.")
   (mode-def 'origin 6 'dec-private #f
             "DECOM: cursor positioning is relative to the scroll region.")
   (mode-def 'autowrap 7 'dec-private #t
             "DECAWM: characters at the right margin wrap to the next line.")
   (mode-def 'autorepeat 8 'dec-private #t
             "DECARM: keys auto-repeat when held.")
   (mode-def 'mouse-x10 9 'dec-private #f
             "X10 mouse reporting.")
   (mode-def 'cursor-blink 12 'dec-private #f
             "xterm cursor-blink mode (also see DECSCUSR).")
   (mode-def 'cursor-visible 25 'dec-private #t
             "DECTCEM: cursor is visible when set.")
   (mode-def 'enable-mode-3 40 'dec-private #f
             "xterm: allow CSI ?3 h to switch to 132-column.")
   (mode-def 'reverse-wrap 45 'dec-private #f
             "DECREVWM: backspace at column 0 wraps to the previous line.")
   (mode-def 'alt-screen-legacy 47 'dec-private #f
             "Legacy alt-screen toggle (superseded by 1047/1049).")
   (mode-def 'keypad-app 66 'dec-private #f
             "DECNKM: keypad sends application sequences.")
   (mode-def 'backarrow 67 'dec-private #f
             "DECBKM: backspace key sends BS (0x08) when set, DEL when reset.")
   (mode-def 'enable-left-right-margin 69 'dec-private #f
             "DECLRMM: allow CSI s to set left/right margins.")
   (mode-def 'mouse-normal 1000 'dec-private #f
             "xterm normal mouse tracking (press + release).")
   (mode-def 'mouse-button-event 1002 'dec-private #f
             "xterm button-event mouse tracking (press + release + drag).")
   (mode-def 'mouse-any-event 1003 'dec-private #f
             "xterm any-event mouse tracking (press + release + drag + motion).")
   (mode-def 'focus-events 1004 'dec-private #f
             "xterm focus-in / focus-out reporting.")
   (mode-def 'mouse-utf8 1005 'dec-private #f
             "UTF-8 mouse coordinate encoding.")
   (mode-def 'mouse-sgr 1006 'dec-private #f
             "SGR mouse coordinate encoding (the modern default).")
   (mode-def 'alt-scroll 1007 'dec-private #t
             "Alt-screen scroll-wheel sends cursor up/down keys.")
   (mode-def 'mouse-urxvt 1015 'dec-private #f
             "urxvt mouse coordinate encoding.")
   (mode-def 'mouse-sgr-pixels 1016 'dec-private #f
             "SGR-pixels mouse coordinate encoding.")
   (mode-def 'ignore-keypad-numlock 1035 'dec-private #t
             "Ignore NumLock when interpreting keypad sequences.")
   (mode-def 'alt-esc-prefix 1036 'dec-private #t
             "Alt-key sends ESC as a prefix.")
   (mode-def 'alt-sends-escape 1039 'dec-private #f
             "Alt-key sends ESC for keys that otherwise send literal bytes.")
   (mode-def 'reverse-wrap-extended 1045 'dec-private #f
             "Extended reverse-wraparound mode.")
   (mode-def 'alt-screen 1047 'dec-private #f
             "Alternate screen buffer (no save/restore of cursor).")
   (mode-def 'save-cursor 1048 'dec-private #f
             "Composite mode: save cursor on set, restore on reset.")
   (mode-def 'alt-screen-save 1049 'dec-private #f
             "Composite mode: save cursor, enter alt-screen, clear; reverse.")
   (mode-def 'bracketed-paste 2004 'dec-private #f
             "Pasted text is bracketed by ESC[200~ and ESC[201~.")
   (mode-def 'sync-output 2026 'dec-private #f
             "Defer rendering between set and reset for tear-free updates.")
   (mode-def 'grapheme-cluster 2027 'dec-private #f
             "Treat incoming codepoints as grapheme-cluster aware.")
   (mode-def 'report-color-scheme 2031 'dec-private #f
             "Report OS light/dark color scheme.")
   (mode-def 'in-band-size-report 2048 'dec-private #f
             "Emit terminal size reports inline as text on resize.")))

(define %mode-by-name
  (let ((h (make-hash-table)))
    (for-each (lambda (def) (hash-set! h (mode-def-name def) def))
              *modes*)
    h))

(define %mode-by-key
  (let ((h (make-hash-table)))
    (for-each (lambda (def)
                (hash-set! h (cons (mode-def-kind def) (mode-def-number def))
                           def))
              *modes*)
    h))

(define (mode-def-by-name name)
  "Return the <mode-def> registered for NAME, or #f if NAME is not a
known mode."
  (hash-ref %mode-by-name name))

(define (mode-def-by-key kind number)
  "Return the <mode-def> for (KIND, NUMBER) where KIND is 'ansi or
'dec-private, or #f if no mode matches."
  (hash-ref %mode-by-key (cons kind number)))

(define-record-type <mode-state>
  (%make-mode-state values saved default)
  mode-state?
  (values  mode-state-values)
  (saved   mode-state-saved)
  (default mode-state-default))

(define (%fresh-defaults)
  (let ((h (make-hash-table)))
    (for-each (lambda (def) (hash-set! h (mode-def-name def)
                                       (mode-def-default def)))
              *modes*)
    h))

(define (%copy-table src)
  (let ((dst (make-hash-table)))
    (hash-for-each (lambda (k v) (hash-set! dst k v)) src)
    dst))

(define (make-mode-state)
  "Return a fresh <mode-state> initialised to the default values from
the *modes* table.  The saved snapshot starts equal to the defaults."
  (let ((defaults (%fresh-defaults)))
    (%make-mode-state (%copy-table defaults)
                      (%copy-table defaults)
                      defaults)))

(define (mode-get state name)
  "Return the current value of mode NAME in STATE.  Unknown NAME
returns #f."
  (hash-ref (mode-state-values state) name #f))

(define (mode-set! state name value)
  "Set mode NAME in STATE to VALUE (a boolean).  Unknown NAME is a
silent no-op so the parser can accept mode numbers we don't yet
recognise without raising."
  (when (hash-ref %mode-by-name name)
    (hash-set! (mode-state-values state) name (and value #t))))

(define (mode-save! state)
  "Snapshot every current mode value in STATE so a later mode-restore!
brings them back."
  (let ((dst (mode-state-saved state)))
    (hash-clear! dst)
    (hash-for-each (lambda (k v) (hash-set! dst k v))
                   (mode-state-values state))))

(define (mode-restore! state)
  "Restore every mode in STATE from the snapshot taken by the most
recent mode-save! (or the defaults if no save has happened)."
  (let ((dst (mode-state-values state)))
    (hash-clear! dst)
    (hash-for-each (lambda (k v) (hash-set! dst k v))
                   (mode-state-saved state))))

(define (mode-reset! state)
  "Restore every mode in STATE to its defined default.  Used by RIS
(full reset)."
  (let ((dst (mode-state-values state)))
    (hash-clear! dst)
    (hash-for-each (lambda (k v) (hash-set! dst k v))
                   (mode-state-default state))))
