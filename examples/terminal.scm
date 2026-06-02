;;; examples/terminal.scm — gcell as a terminal emulator.
;;;
;;; Spawns $SHELL on a fresh PTY, feeds its byte stream through
;;; gcell's VT emulator (`term-process-output!`), renders the cell grid into
;;; one full-window widget.  Keystrokes translate back to PTY writes;
;;; the engine forwards <resize> to TIOCSWINSZ on the master fd.
;;;
;;; Defaults to the webui backend so the shell paints into a fresh
;;; browser window -- running this on top of an ANSI backend inside
;;; the user's host terminal would put two terminals in the same
;;; bytestream and the escape sequences fight each other.
;;;
;;; Run: guile -L . -L /path/to/guile-webui examples/terminal.scm
;;; Exit: type `exit` (or Ctrl-D) in the shell.
;;;
;;; The library only contributes <term> + term-write! (the VT
;;; parser) + the cells-node view primitive + the widget/engine
;;; plumbing.  PTY FFI, the key->bytes table, and the widget all
;;; live in this single file -- this is an example app, not a
;;; gcell-shipped feature.

(use-modules (gcell)
             ((gcell engine) #:select (start-engine! send force-render!))
             ((gcell engine-types) #:select (engine))
             ((gcell backend-webui) #:select (webui-backend))
             ((gcell view) #:select (make-cells-node))
             ((gcell term types)
              #:select (make-term term-resize!
                        term-chars term-faces term-width term-height
                        term-cursor-x term-cursor-y))
             ((gcell term parser) #:select (term-process-bytes!))
             ((gcell term utf8)   #:select (make-utf8-decoder))
             ((gcell protocol) #:select (size))
             (oop goops)
             (ice-9 match)
             (ice-9 threads)
             (rnrs bytevectors)
             (system foreign)
             ((fibers) #:select (run-fibers)))


;;;
;;; PTY FFI.
;;;
;;; openpty(3) lives in libutil; ioctl(2)/read(2)/write(2) in libc.
;;; The two ioctls: TIOCSCTTY hands the child its controlling tty,
;;; TIOCSWINSZ pushes a new rect size into the slave so the child
;;; reflows on SIGWINCH.  Constants are Linux x86_64; lift to a
;;; per-platform table in real code.
;;;

;; Distros ship "libc.so" as a linker script; we need the actual
;; shared object.  libc.so.6 is the SONAME on every linux-glibc build
;; back through ~2.0, so it's a reliable target for dlopen.  Glibc
;; 2.34+ folded libutil into libc; older systems still keep a
;; separate libutil.so.6.  Try libc first, libutil as fallback.
(define %libc (dynamic-link "libc.so.6"))
(define %openpty-lib
  (cond
   ((false-if-exception (dynamic-func "openpty" %libc)) %libc)
   (else (dynamic-link "libutil.so.1"))))

(define %openpty
  (pointer->procedure int (dynamic-func "openpty" %openpty-lib)
                      (list '* '* '* '* '*)))

(define %ioctl
  (pointer->procedure int (dynamic-func "ioctl" %libc)
                      (list int unsigned-long '*)))

(define %read
  (pointer->procedure long (dynamic-func "read" %libc)
                      (list int '* size_t)))

(define %write
  (pointer->procedure long (dynamic-func "write" %libc)
                      (list int '* size_t)))

(define %tiocsctty  #x540E)
(define %tiocswinsz #x5414)

(define (open-pty rows cols)
  "Allocate a PTY pair sized to ROWS x COLS.  Returns
(master-fd . slave-fd)."
  (let ((mfd (make-bytevector 4 0))
        (sfd (make-bytevector 4 0))
        (ws  (make-bytevector 8 0)))  ; struct winsize: rows cols xpx ypx
    (bytevector-u16-native-set! ws 0 rows)
    (bytevector-u16-native-set! ws 2 cols)
    (let ((rc (%openpty (bytevector->pointer mfd)
                        (bytevector->pointer sfd)
                        %null-pointer %null-pointer
                        (bytevector->pointer ws))))
      (when (negative? rc) (error "openpty failed"))
      (cons (bytevector-s32-native-ref mfd 0)
            (bytevector-s32-native-ref sfd 0)))))

(define (push-winsize! fd rows cols)
  (let ((ws (make-bytevector 8 0)))
    (bytevector-u16-native-set! ws 0 rows)
    (bytevector-u16-native-set! ws 2 cols)
    (%ioctl fd %tiocswinsz (bytevector->pointer ws))))

(define (spawn-shell rows cols)
  "Fork $SHELL with stdin/stdout/stderr wired to a fresh PTY.
Returns (master-fd . child-pid).  Child does setsid + TIOCSCTTY +
dup2 + execlp; parent keeps the master fd and the child's pid."
  (match (open-pty rows cols)
    ((master . slave)
     (let ((pid (primitive-fork)))
       (cond
        ((zero? pid)
         (setsid)
         (%ioctl slave %tiocsctty %null-pointer)
         (dup2 slave 0) (dup2 slave 1) (dup2 slave 2)
         (when (> slave 2) (close-fdes slave))
         (close-fdes master)
         (let ((sh (or (getenv "SHELL") "/bin/sh")))
           (execlp sh sh))
         (primitive-_exit 127))
        (else
         (close-fdes slave)
         (cons master pid)))))))


;;;
;;; Key -> bytes.  Mirror of gcell/input.scm in reverse: take the
;;; (sym, mods) the engine hands us and emit what the child wants.
;;; Covers ASCII + control combos + arrows + navigation + escape;
;;; expand for function keys, modifier-encoded arrows, kitty kbd.
;;;

(define (bv . octets)
  (let ((b (make-bytevector (length octets))))
    (let loop ((i 0) (xs octets))
      (cond
       ((null? xs) b)
       (else (bytevector-u8-set! b i (car xs))
             (loop (+ i 1) (cdr xs)))))))

(define (prepend-esc bv)
  (let ((out (make-bytevector (+ 1 (bytevector-length bv)) 0)))
    (bytevector-u8-set! out 0 27)
    (bytevector-copy! bv 0 out 1 (bytevector-length bv))
    out))

(define (key->bytes sym mods)
  (cond
   ((char? sym)
    (let ((cp (char->integer sym)))
      (cond
       ;; Ctrl-A..Z (case-insensitive) → 0x01..0x1A.  Ctrl-space → NUL.
       ((and (memq 'control mods)
             (or (<= 65 cp 90) (<= 97 cp 122)))
        (bv (logand cp #x1f)))
       ((and (memq 'control mods) (= cp 32))
        (bv 0))
       ;; Alt-prefix: ESC followed by the char's UTF-8 bytes.
       ((memq 'alt mods)
        (prepend-esc (string->utf8 (string sym))))
       (else (string->utf8 (string sym))))))
   ((eq? sym 'enter)     (bv 13))
   ((eq? sym 'tab)       (bv 9))
   ((eq? sym 'escape)    (bv 27))
   ((eq? sym 'backspace) (bv 127))
   ((eq? sym 'delete)    (string->utf8 "\x1b[3~"))
   ((eq? sym 'up)        (string->utf8 "\x1b[A"))
   ((eq? sym 'down)      (string->utf8 "\x1b[B"))
   ((eq? sym 'right)     (string->utf8 "\x1b[C"))
   ((eq? sym 'left)      (string->utf8 "\x1b[D"))
   ((eq? sym 'home)      (string->utf8 "\x1bOH"))
   ((eq? sym 'end)       (string->utf8 "\x1bOF"))
   ((eq? sym 'page-up)   (string->utf8 "\x1b[5~"))
   ((eq? sym 'page-down) (string->utf8 "\x1b[6~"))
   (else #f)))

(define (write-bytes! fd bv)
  (%write fd (bytevector->pointer bv) (bytevector-length bv)))

(define (bracketed-paste bv)
  ;; Most shells / editors negotiate bracketed paste; just always
  ;; wrap so paste lands as one chunk instead of a stream of keys.
  (let* ((pre  (string->utf8 "\x1b[200~"))
         (post (string->utf8 "\x1b[201~"))
         (out  (make-bytevector (+ (bytevector-length pre)
                                   (bytevector-length bv)
                                   (bytevector-length post))
                                0)))
    (bytevector-copy! pre 0 out 0 (bytevector-length pre))
    (bytevector-copy! bv  0 out (bytevector-length pre)
                      (bytevector-length bv))
    (bytevector-copy! post 0 out (+ (bytevector-length pre)
                                    (bytevector-length bv))
                      (bytevector-length post))
    out))


;;;
;;; Widget.
;;;
;;; The widget owns the master-fd, the child pid, the in-memory
;;; <term>, and a back-pointer to the engine so the reader thread
;;; can poke it for a redraw.  View just hands the renderer one
;;; cells-node over the term's chars+faces buffers.
;;;

(define-class <pty-emulator> (<focusable>)
  (term    #:init-keyword #:term #:getter pty-term)
  (fd      #:init-keyword #:fd   #:getter pty-fd)
  (pid     #:init-keyword #:pid  #:getter pty-pid)
  (engine  #:init-value #f       #:accessor pty-engine)
  ;; Debounced TIOCSWINSZ.  Browser drags fire a resize msg every few
  ;; ms; SIGWINCHing bash on each one reflows mid-line and produces
  ;; prompt-spam scrollback.  These slots buffer the latest requested
  ;; grid; the pump thread pushes it to the PTY once the burst has been
  ;; quiet long enough that the user has actually let go of the edge.
  (pending-cols   #:init-value #f #:accessor pty-pending-cols)
  (pending-rows   #:init-value #f #:accessor pty-pending-rows)
  (last-resize    #:init-value 0  #:accessor pty-last-resize)
  (winsize-mutex  #:init-form (make-mutex) #:getter pty-winsize-mutex))

(define %resize-debounce-its
  ;; 200ms in this Guile's internal time units.  Long enough to swallow
  ;; a continuous drag, short enough that bash sees the new size before
  ;; the user starts typing into the resized window.
  (quotient (* internal-time-units-per-second 200) 1000))

(define-method (view (e <pty-emulator>))
  (let ((t (pty-term e)))
    (overlay
     (make-cells-node (term-chars t) (term-faces t)
                      (term-width t) (term-height t))
     (pin (term-cursor-x t) (term-cursor-y t)
          (place-cursor 0 0 #:style 'block)))))

(define-method (update (e <pty-emulator>) (msg <key>))
  (let ((bv (key->bytes (key-sym msg) (key-mods msg))))
    (when bv (write-bytes! (pty-fd e) bv))
    (cons e #f)))

(define-method (update (e <pty-emulator>) (msg <paste>))
  (write-bytes! (pty-fd e) (bracketed-paste (string->utf8 (paste-text msg))))
  (cons e #f))

(define-method (update (e <pty-emulator>) (msg <resize>))
  (let ((w (resize-width msg))
        (h (resize-height msg)))
    (term-resize! (pty-term e) w h)
    (with-mutex (pty-winsize-mutex e)
      (set! (pty-pending-cols e) w)
      (set! (pty-pending-rows e) h)
      (set! (pty-last-resize e) (get-internal-real-time)))
    (cons e #f)))

(define (spawn-winsize-pump! e)
  "Flush the debounced TIOCSWINSZ once the incoming resize stream has
been quiet for %resize-debounce-its.  Polls every 50ms; cheap, and
survives transient errors so a single failed ioctl can't kill it."
  (call-with-new-thread
   (lambda ()
     (let loop ()
       (catch #t
         (lambda ()
           (usleep 50000)
           (let ((cols #f) (rows #f))
             (with-mutex (pty-winsize-mutex e)
               (let ((c (pty-pending-cols e))
                     (r (pty-pending-rows e))
                     (last (pty-last-resize e)))
                 (when (and c r (positive? last)
                            (> (- (get-internal-real-time) last)
                               %resize-debounce-its))
                   (set! cols c)
                   (set! rows r)
                   (set! (pty-pending-cols e) #f)
                   (set! (pty-pending-rows e) #f)
                   (set! (pty-last-resize e) 0))))
             (when (and cols rows)
               (push-winsize! (pty-fd e) rows cols))))
         (lambda args
           (format (current-error-port)
                   "winsize-pump error: ~s~%" args)))
       (loop)))))


;;;
;;; PTY -> term pump.  An OS thread does the blocking read(2) so it
;;; doesn't tie up the fibers scheduler; gcell's `send` is mutex-
;;; protected so calling it across threads is fine.  After each
;;; chunk we re-make the widget instance with `update-slots` so the
;;; engine's eq?-based view cache invalidates and a fresh frame
;;; goes out.  A real implementation would use a fibers-aware port.
;;;

(define-class <pty-data> ()
  (bytes #:init-keyword #:bytes #:getter pty-data-bytes))

(define-method (update (e <pty-emulator>) (msg <pty-data>))
  (cons e #f))

(define (spawn-reader! e eng)
  (call-with-new-thread
   (lambda ()
     (let ((fd      (pty-fd e))
           (t       (pty-term e))
           (buf     (make-bytevector 4096 0))
           (decoder (make-utf8-decoder)))
       (let loop ()
         (let ((n (%read fd (bytevector->pointer buf) 4096)))
           (cond
            ((<= n 0)
             (send eng 'quit))
            (else
             ;; Decoder carries partial multi-byte codepoints across
             ;; read(2) boundaries; invalid bytes surface as U+FFFD
             ;; instead of dropping the chunk.  utf8->string would
             ;; raise and the catch would silently lose the bytes,
             ;; which is how bash's startup PS1 was disappearing.
             (term-process-bytes! t decoder buf 0 n)
             (force-render! eng)
             (loop)))))))))


;;;
;;; Boot.
;;;
;;; We instantiate the engine ourselves (instead of using run-app)
;;; so we can hand the engine reference to the widget before the
;;; reader thread starts.  Start-engine! does the rest -- backend
;;; init, fiber spawning, initial <init> + <resize>, and the wait
;;; on stop-ch.
;;;

(define (bell-pipe)
  ;; Same shape gcell's internal helper builds: an ISO-8859-1 pipe
  ;; with the write side unbuffered, used by `send` to wake the
  ;; engine's event-loop fiber from another thread.
  (let ((p (pipe)))
    (set-port-encoding! (car p) "ISO-8859-1")
    (set-port-encoding! (cdr p) "ISO-8859-1")
    (setvbuf (cdr p) 'none)
    p))

(define (main)
  (let* ((rows 24)
         (cols 80)
         (master+pid (spawn-shell rows cols))
         (master (car master+pid))
         (pid    (cdr master+pid))
         (term   (make-term #:width cols #:height rows))
         (widget (make <pty-emulator>
                   #:term term #:fd master #:pid pid))
         (eng    (engine #:backend     (webui-backend #:size (size cols rows))
                         #:theme       default-theme
                         #:keymap      (keymap)
                         #:title       "gcell-shell"
                         #:mouse-mode  'off
                         #:cursor      'block
                         #:alt-screen? #t
                         #:show-log?   #f
                         #:root        widget
                         #:msg-bell    (bell-pipe)
                         #:stop-ch     (bell-pipe))))
    (set! (pty-engine widget) eng)
    (spawn-winsize-pump! widget)
    (run-fibers
     (lambda ()
       (spawn-reader! widget eng)
       (start-engine! eng))
     #:hz 0)))

(main)
