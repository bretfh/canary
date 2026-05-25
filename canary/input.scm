(define-module (canary input)
  #:use-module (canary protocol)
  #:use-module (ice-9 textual-ports)
  #:export (read-key-msg
            enable-input-logging
            disable-input-logging))

(define *input-log-enabled* #f)
(define *input-log-file* "/tmp/guile-canary-input-debug.log")

(define (enable-input-logging . args)
  (when (pair? args)
    (set! *input-log-file* (car args)))
  (set! *input-log-enabled* #t)
  (let ((port (open-file *input-log-file* "a")))
    (display "=== Input logging enabled ===\n" port)
    (close-port port))
  #t)

(define (disable-input-logging)
  (set! *input-log-enabled* #f)
  #t)

(define (%ilog fmt . args)
  (when *input-log-enabled*
    (let ((port (open-file *input-log-file* "a")))
      (apply format port fmt args)
      (newline port)
      (close-port port))))

(define (read-key-msg)
  (let ((port (current-input-port)))
    (if (char-ready? port)
        (let ((char (read-char port)))
          (when char
            (%ilog "read-key-msg: char='~a' code=~d" char (char->integer char))
            (cond
             ((char=? char #\escape)
              (%ilog "read-key-msg: ESC detected -> parse-escape-start")
              (parse-escape-start port))
             ((= (char->integer char) 127)
              (%ilog "read-key-msg: DEL(127) -> :backspace")
              (key 'backspace))
             ((< (char->integer char) 32)
              (let ((k (ctrl-char-to-key char)))
                (%ilog "read-key-msg: control char ~d -> ~a" (char->integer char) k)
                (key k 'control)))
             (else
              (%ilog "read-key-msg: graphic '~a'" char)
              (key char)))))
        #f)))

(define (ctrl-char-to-key char)
  (let ((code (char->integer char)))
    (case code
      ((8)  'backspace)
      ((9)  'tab)
      ((10) 'enter)
      ((13) 'enter)
      (else (integer->char (+ code 96))))))

(define (parse-escape-start port)
  (let loop ((tries 0))
    (cond
     ((and (not (char-ready? port)) (< tries 8))
      (usleep 5000)
      (loop (+ tries 1)))
     (else
      (%ilog "parse-escape-start: waited ~d ticks, ready=~a" tries (char-ready? port))
      (if (char-ready? port)
          (let ((next (read-char port)))
            (%ilog "parse-escape-start: next='~a' code=~d" next (char->integer next))
            (if next
                (parse-escape-sequence next port)
                (key 'escape)))
          (begin
            (%ilog "parse-escape-start: lone ESC -> escape")
            (key 'escape)))))))

(define (parse-escape-sequence char port)
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
  (apply key sym mods))

(define (read-csi-params-and-final port first-char)
  "Already consumed FIRST-CHAR (a digit). Read remaining digits + ';'
separators until a non-numeric / non-';' terminator. Return (values
params final-char). Each param is a number or #f for missing.
Returns (#f #f) if the stream ends before a terminator."
  (let loop ((cur (list first-char)) (params '()))
    (cond
     ((not (char-ready? port))
      (values #f #f))
     (else
      (let ((c (read-char port)))
        (cond
         ((char-numeric? c) (loop (append cur (list c)) params))
         ((char=? c #\;)
          (loop '() (cons (if (null? cur) #f
                              (string->number (list->string cur)))
                          params)))
         (else
          (let ((final-params
                 (reverse (cons (if (null? cur) #f
                                    (string->number (list->string cur)))
                                params))))
            (values final-params c)))))))))

(define (parse-csi-sequence port)
  (if (not (char-ready? port))
      (key 'unknown)
      (let ((ch (read-char port)))
        (%ilog "parse-csi-sequence: ch='~a' (code ~a)" ch (char->integer ch))
        (cond
         ((char=? ch #\<)         (parse-mouse-sequence port))
         ((char=? ch #\I)         (focus))
         ((char=? ch #\O)         (blur))
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
               (else (key 'unknown))))))
         (else
          (let drain ()
            (when (char-ready? port) (read-char port) (drain)))
          (key 'unknown))))))

(define (parse-ss3-sequence port)
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
    (key 'paste)))
