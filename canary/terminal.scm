(define-module (canary terminal)
  #:use-module (canary protocol)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:export (enter-raw-mode
            exit-raw-mode
            get-terminal-size
            hide-cursor
            show-cursor
            clear-screen
            move-to
            esc
            csi
            enter-alternate-screen
            exit-alternate-screen
            enable-mouse
            disable-mouse
            with-raw-terminal
            setup-signal-handlers
            setup-resize-handler
            key-ready?
            read-key))

(define %libc (dynamic-link))
(define %termios-size 128)
(define %stdin-fd 0)
(define %original-termios #f)

(define %sysname (utsname:sysname (uname)))
(define %linux? (string=? %sysname "Linux"))

(define %TIOCGWINSZ (if %linux? #x5413 #x40087468))
(define %O_RDONLY 0)

(define %tcgetattr
  (pointer->procedure int (dynamic-func "tcgetattr" %libc) (list int '*)))

(define %tcsetattr
  (pointer->procedure int (dynamic-func "tcsetattr" %libc) (list int int '*)))

(define %cfmakeraw
  (pointer->procedure void (dynamic-func "cfmakeraw" %libc) (list '*)))

(define %isatty
  (pointer->procedure int (dynamic-func "isatty" %libc) (list int)))

(define %ioctl
  (pointer->procedure int (dynamic-func "ioctl" %libc) (list int unsigned-long '*)))

(define %open
  (pointer->procedure int (dynamic-func "open" %libc) (list '* int)))

(define %close
  (pointer->procedure int (dynamic-func "close" %libc) (list int)))

(define (enter-raw-mode)
  "Switch stdin into raw mode (no canonical processing, no echo).
Stashes the original termios on the first call so `exit-raw-mode`
can restore it.  Errors when stdin is not a TTY or termios syscalls
fail.

The fd's flags are left alone: every read in canary is guarded by
`char-ready?', so stdin works blocking, and setting O_NONBLOCK here
would leak onto stdout when fds 0 and 1 share one open file
description (a shell or openvt duping the tty) — under fibers'
suspendable ports a mid-frame EAGAIN then parks the event-loop
fiber on tty writability, which fbcon never reliably signals."
  (unless (= 1 (%isatty %stdin-fd))
    (error "stdin is not a TTY"))
  (let ((termios (make-bytevector %termios-size 0)))
    (when (< (%tcgetattr %stdin-fd (bytevector->pointer termios)) 0)
      (error "tcgetattr failed"))
    (unless %original-termios
      (set! %original-termios (bytevector-copy termios)))
    (%cfmakeraw (bytevector->pointer termios))
    (when (< (%tcsetattr %stdin-fd 0 (bytevector->pointer termios)) 0)
      (error "tcsetattr failed"))))

(define (exit-raw-mode)
  "Restore the termios state captured by the most recent
`enter-raw-mode`.  No-op if raw mode wasn't entered."
  (when %original-termios
    (%tcsetattr %stdin-fd 0 (bytevector->pointer %original-termios))
    (set! %original-termios #f)))

(define (esc str)
  "Return STR prefixed with an ESC byte."
  (string-append "\x1b" str))

(define (csi . args)
  "Return the concatenation of ARGS prefixed with CSI (ESC[)."
  (apply string-append "\x1b[" args))

(define (hide-cursor)
  "Emit the DECTCEM hide-cursor sequence to stdout and flush."
  (display (csi "?25l"))
  (force-output))

(define (show-cursor)
  "Emit the DECTCEM show-cursor sequence to stdout and flush."
  (display (csi "?25h"))
  (force-output))

(define (clear-screen)
  "Emit ESC[2J ESC[H to clear the screen and home the cursor."
  (display (csi "2J"))
  (display (csi "H"))
  (force-output))

(define (enter-alternate-screen)
  "Switch the terminal into its alternate-screen buffer."
  (display (csi "?1049h"))
  (force-output))

(define (exit-alternate-screen)
  "Switch the terminal back to the primary-screen buffer."
  (display (csi "?1049l"))
  (force-output))

(define (enable-mouse)
  "Enable SGR-format mouse reporting (press / motion)."
  (display (csi "?1000h"))
  (display (csi "?1002h"))
  (display (csi "?1015h"))
  (display (csi "?1006h"))
  (force-output))

(define (disable-mouse)
  "Disable mouse reporting (undoing the modes enable-mouse set)."
  (display (csi "?1006l"))
  (display (csi "?1015l"))
  (display (csi "?1002l"))
  (display (csi "?1000l"))
  (force-output))

(define (move-to x y)
  "Move the cursor to 1-indexed column X, row Y."
  (display (csi (number->string y) ";" (number->string x) "H"))
  (force-output))

(define (get-terminal-size)
  "Return the terminal size as a <size>.  Tries TIOCGWINSZ via
ioctl first, then falls back to `stty size`, then to 80x24."
  (or (catch #t
        (lambda ()
          (let ((ws (make-bytevector 8 0)))
            (and (zero? (%ioctl %stdin-fd %TIOCGWINSZ (bytevector->pointer ws)))
                 (let ((rows (bytevector-u16-native-ref ws 0))
                       (cols (bytevector-u16-native-ref ws 2)))
                   (and (positive? rows) (positive? cols)
                        (size cols rows))))))
        (lambda _ #f))
      (catch #t
        (lambda ()
          (let* ((port   (open-input-pipe "sh -c 'stty size < /dev/tty'"))
                 (output (read-line port)))
            (close-pipe port)
            (cond
             ((eof-object? output) (size 80 24))
             (else
              (let ((parts (string-split output #\space)))
                (cond
                 ((= 2 (length parts))
                  (let ((r (string->number (car parts)))
                        (c (string->number (cadr parts))))
                    (if (and r c (positive? r) (positive? c))
                        (size c r)
                        (size 80 24))))
                 (else (size 80 24))))))))
        (lambda _ (size 80 24)))))

(define-syntax-rule (with-raw-terminal body ...)
  "Evaluate BODY with stdin in raw mode, the cursor hidden, and the
screen cleared.  Always restores the cursor and termios on exit
(normal or via non-local return)."
  (dynamic-wind
    (lambda ()
      (enter-raw-mode)
      (hide-cursor)
      (clear-screen))
    (lambda () body ...)
    (lambda ()
      (show-cursor)
      (exit-raw-mode))))

(define (setup-signal-handlers cleanup-thunk)
  "Setup signal handlers to call cleanup and exit"
  (sigaction SIGINT
    (lambda (sig)
      (cleanup-thunk)
      (primitive-exit 0)))
  (sigaction SIGTERM
    (lambda (sig)
      (cleanup-thunk)
      (primitive-exit 0))))

(define (setup-resize-handler thunk)
  "Install a SIGWINCH handler that calls THUNK on terminal resize."
  (sigaction SIGWINCH (lambda (sig) (thunk))))

(define (key-ready?)
  "Check if a key is ready to be read from stdin"
  (char-ready? (current-input-port)))

(define (read-key)
  "Read a single character from stdin (non-blocking)"
  (catch 'system-error
    (lambda ()
      (if (char-ready? (current-input-port))
          (read-char (current-input-port))
          #f))
    (lambda (key . args)
      ;; EAGAIN/EWOULDBLOCK - no data available
      #f)))
