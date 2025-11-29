(define-module (tuition terminal)
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
            key-ready?
            read-key))

(define %libc (dynamic-link))
(define %termios-size 128)
(define %stdin-fd 0)
(define %original-termios #f)
(define %original-flags #f)
(define %TIOCGWINSZ #x40087468)  ; macOS/BSD value
(define %O_RDONLY 0)
(define %O_NONBLOCK 4)  ; macOS/BSD
(define %F_GETFL 3)
(define %F_SETFL 4)

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

(define %fcntl
  (pointer->procedure int (dynamic-func "fcntl" %libc) (list int int int)))

(define (enter-raw-mode)
  (unless (= 1 (%isatty %stdin-fd))
    (error "stdin is not a TTY"))
  ;; Set termios to raw mode
  (let ((termios (make-bytevector %termios-size 0)))
    (when (< (%tcgetattr %stdin-fd (bytevector->pointer termios)) 0)
      (error "tcgetattr failed"))
    (unless %original-termios
      (set! %original-termios (bytevector-copy termios)))
    (%cfmakeraw (bytevector->pointer termios))
    (when (< (%tcsetattr %stdin-fd 0 (bytevector->pointer termios)) 0)
      (error "tcsetattr failed")))
  ;; Set stdin to non-blocking
  (let ((flags (%fcntl %stdin-fd %F_GETFL 0)))
    (when (>= flags 0)
      (unless %original-flags
        (set! %original-flags flags))
      (%fcntl %stdin-fd %F_SETFL (logior flags %O_NONBLOCK)))))

(define (exit-raw-mode)
  ;; Restore original termios
  (when %original-termios
    (%tcsetattr %stdin-fd 0 (bytevector->pointer %original-termios))
    (set! %original-termios #f))
  ;; Restore original flags
  (when %original-flags
    (%fcntl %stdin-fd %F_SETFL %original-flags)
    (set! %original-flags #f)))

(define (esc str)
  (string-append "\x1b" str))

(define (csi . args)
  (apply string-append "\x1b[" args))

(define (hide-cursor)
  (display (csi "?25l"))
  (force-output))

(define (show-cursor)
  (display (csi "?25h"))
  (force-output))

(define (clear-screen)
  (display (csi "2J"))
  (display (csi "H"))
  (force-output))

(define (enter-alternate-screen)
  (display (csi "?1049h"))
  (force-output))

(define (exit-alternate-screen)
  (display (csi "?1049l"))
  (force-output))

(define (enable-mouse)
  (display (csi "?1000h"))
  (display (csi "?1002h"))
  (display (csi "?1015h"))
  (display (csi "?1006h"))
  (force-output))

(define (disable-mouse)
  (display (csi "?1006l"))
  (display (csi "?1015l"))
  (display (csi "?1002l"))
  (display (csi "?1000l"))
  (force-output))

(define (move-to x y)
  (display (csi (number->string y) ";" (number->string x) "H"))
  (force-output))

(define (get-terminal-size)
  "Get terminal size as (cols . rows)"
  (catch #t
    (lambda ()
      (let* ((port (open-input-pipe "sh -c 'stty size < /dev/tty'"))
             (output (read-line port)))
        (close-pipe port)
        (if (eof-object? output)
            (cons 80 24)
            (let ((parts (string-split output #\space)))
              (if (= 2 (length parts))
                  (cons (string->number (cadr parts))
                        (string->number (car parts)))
                  (cons 80 24))))))
    (lambda _ (cons 80 24))))

(define-syntax-rule (with-raw-terminal body ...)
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
