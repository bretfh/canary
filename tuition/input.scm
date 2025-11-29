;;; input.scm --- Input handling and key event parsing for Guile Tuition

(define-module (tuition input)
  #:use-module (tuition protocol)
  #:use-module (ice-9 textual-ports)
  #:use-module (oop goops)
  #:export (read-key-msg
            enable-input-logging
            disable-input-logging))

;;; Input logging (for debugging)
(define *input-log-enabled* #f)
(define *input-log-file* "/tmp/guile-tuition-input-debug.log")

(define (enable-input-logging . args)
  "Enable verbose input parsing logs"
  (when (pair? args)
    (set! *input-log-file* (car args)))
  (set! *input-log-enabled* #t)
  (let ((port (open-file *input-log-file* "a")))
    (display "=== Input logging enabled ===\n" port)
    (close-port port))
  #t)

(define (disable-input-logging)
  "Disable input parsing logs"
  (set! *input-log-enabled* #f)
  #t)

(define (%ilog fmt . args)
  "Internal: write a log line if enabled"
  (when *input-log-enabled*
    (let ((port (open-file *input-log-file* "a")))
      (apply format port fmt args)
      (newline port)
      (close-port port))))

;;; Main entry point
(define (read-key-msg)
  "Read a single key from stdin and return a message object (<key-msg>, <mouse-msg>, etc.).
   Returns #f if no input is available."
  (let ((port (current-input-port)))
    (if (char-ready? port)
        (let ((char (read-char port)))
          (when char
            (%ilog "read-key-msg: char='~a' code=~d" char (char->integer char))
            (cond
             ;; Escape sequences
             ((char=? char #\escape)
              (%ilog "read-key-msg: ESC detected -> parse-escape-start")
              (parse-escape-start port))

             ;; ASCII DEL (127) - commonly backspace
             ((= (char->integer char) 127)
              (%ilog "read-key-msg: DEL(127) -> :backspace")
              (make <key-msg> #:key 'backspace))

             ;; Control characters (< 32)
             ((< (char->integer char) 32)
              (let ((k (ctrl-char-to-key char)))
                (%ilog "read-key-msg: control char ~d -> ~a" (char->integer char) k)
                (make <key-msg> #:key k #:ctrl #t)))

             ;; Regular characters
             (else
              (%ilog "read-key-msg: graphic '~a'" char)
              (make <key-msg> #:key char)))))
        #f)))

(define (ctrl-char-to-key char)
  "Convert a control character to its key representation"
  (let ((code (char->integer char)))
    (case code
      ((8) 'backspace)
      ((9) 'tab)
      ((10) 'enter)
      ((13) 'enter)
      ;; For other control chars, return the corresponding letter
      ;; Ctrl+A is code 1, Ctrl+Z is code 26
      (else (integer->char (+ code 96))))))

(define (parse-escape-start port)
  "Parse an escape sequence after reading ESC"
  ;; Wait briefly for next character in sequence
  (let loop ((tries 0))
    (cond
     ((and (not (char-ready? port)) (< tries 8))
      (usleep 5000) ; 5ms
      (loop (+ tries 1)))
     (else
      (%ilog "parse-escape-start: waited ~d ticks, ready=~a" tries (char-ready? port))
      (if (char-ready? port)
          (let ((next (read-char port)))
            (%ilog "parse-escape-start: next='~a' code=~d" next (char->integer next))
            (if next
                (parse-escape-sequence next port)
                (make <key-msg> #:key 'escape)))
          ;; No following char - just escape key
          (begin
            (%ilog "parse-escape-start: lone ESC -> escape")
            (make <key-msg> #:key 'escape)))))))

(define (parse-escape-sequence char port)
  "Parse an escape sequence starting after ESC"
  (cond
   ;; CSI sequences (ESC [)
   ((char=? char #\[)
    (%ilog "parse-escape-sequence: CSI '['")
    (parse-csi-sequence port))

   ;; SS3 sequences (ESC O) - some terminals use for arrows/Home/End
   ((char=? char #\O)
    (%ilog "parse-escape-sequence: SS3 'O'")
    (parse-ss3-sequence port))

   ;; Alt+key (ESC followed by graphic char)
   ((char-alphabetic? char)
    (make <key-msg> #:key char #:alt #t))

   ;; ESC + DEL (M-Backspace in some terminals)
   ((= (char->integer char) 127)
    (make <key-msg> #:key 'backspace #:alt #t))

   ;; Unknown escape sequence
   (else
    (%ilog "parse-escape-sequence: unknown ESC seq start '~a'" char)
    (make <key-msg> #:key 'escape))))

(define (parse-csi-sequence port)
  "Parse a CSI (Control Sequence Introducer) sequence (ESC [)"
  (if (not (char-ready? port))
      (make <key-msg> #:key 'unknown)
      (let ((ch (read-char port)))
        (%ilog "parse-csi-sequence: ch='~a' (code ~a)" ch (char->integer ch))
        (cond
         ;; Mouse tracking: ESC [ < ...
         ((char=? ch #\<)
          (parse-mouse-sequence port))

         ;; Navigation keys: arrows, Home, End, Backtab
         ((memv ch '(#\A #\B #\C #\D #\H #\F #\Z))
          (case ch
            ((#\A) (%ilog "parse-csi-sequence: -> up") (make <key-msg> #:key 'up))
            ((#\B) (%ilog "parse-csi-sequence: -> down") (make <key-msg> #:key 'down))
            ((#\C) (%ilog "parse-csi-sequence: -> right") (make <key-msg> #:key 'right))
            ((#\D) (%ilog "parse-csi-sequence: -> left") (make <key-msg> #:key 'left))
            ((#\H) (%ilog "parse-csi-sequence: -> home") (make <key-msg> #:key 'home))
            ((#\F) (%ilog "parse-csi-sequence: -> end") (make <key-msg> #:key 'end))
            ((#\Z) (%ilog "parse-csi-sequence: -> backtab") (make <key-msg> #:key 'backtab))))

         ;; Digits: e.g., 3~ for Delete, 200~ for bracketed paste
         ((char-numeric? ch)
          (let loop ((digits (list ch))
                     (term #f))
            (if (and (not term)
                     (char-ready? port)
                     (let ((c (peek-char port)))
                       (or (char-numeric? c) (char=? c #\~) (char=? c #\;))))
                (let ((c (read-char port)))
                  (if (or (char=? c #\~) (char=? c #\;))
                      (loop digits c)
                      (loop (append digits (list c)) term)))
                (begin
                  (%ilog "parse-csi-sequence: digits='~a' term='~a'"
                         (list->string digits) term)
                  (if (and term (char=? term #\~))
                      (let ((num (string->number (list->string digits))))
                        (case num
                          ((3) (%ilog "parse-csi-sequence: -> delete")
                               (make <key-msg> #:key 'delete))
                          ((200) (%ilog "parse-csi-sequence: bracketed paste start")
                                 (parse-bracketed-paste port))
                          (else (make <key-msg> #:key 'unknown))))
                      (make <key-msg> #:key 'unknown))))))

         (else
          ;; Consume any remaining chars then return unknown
          (let loop ()
            (when (char-ready? port)
              (read-char port)
              (loop)))
          (make <key-msg> #:key 'unknown))))))

(define (parse-ss3-sequence port)
  "Parse SS3 sequence (ESC O) - used by some terminals for function keys"
  (if (not (char-ready? port))
      (make <key-msg> #:key 'unknown)
      (let ((ch (read-char port)))
        (%ilog "parse-ss3-sequence: ch='~a'" ch)
        (case ch
          ((#\A) (make <key-msg> #:key 'up))
          ((#\B) (make <key-msg> #:key 'down))
          ((#\C) (make <key-msg> #:key 'right))
          ((#\D) (make <key-msg> #:key 'left))
          ((#\H) (make <key-msg> #:key 'home))
          ((#\F) (make <key-msg> #:key 'end))
          (else (make <key-msg> #:key 'unknown))))))

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
        (let ((button (list-ref params 2))
              (x (list-ref params 1))
              (y (list-ref params 0))
              (action (if (char=? term #\M) 'press 'release)))
          (%ilog "parse-mouse-sequence: btn=~a x=~a y=~a action=~a" button x y action)
          (cond
           ;; Scroll events (button 64 = scroll up, 65 = scroll down)
           ((= button 64)
            (make <mouse-msg> #:x x #:y y #:button 64 #:action 'scroll-up))
           ((= button 65)
            (make <mouse-msg> #:x x #:y y #:button 65 #:action 'scroll-down))
           ;; Regular click/drag
           (else
            (make <mouse-msg> #:x x #:y y #:button button #:action action))))
        (make <key-msg> #:key 'unknown))))

(define (parse-bracketed-paste port)
  "Parse bracketed paste sequence ESC[200~ ... ESC[201~"
  (%ilog "parse-bracketed-paste: reading pasted text")
  (let ((text ""))
    ;; Read until we see ESC[201~
    (let loop ()
      (when (char-ready? port)
        (let ((ch (read-char port)))
          (cond
           ((char=? ch #\escape)
            ;; Check if this is the end marker
            (if (and (char-ready? port)
                    (char=? (peek-char port) #\[))
                (begin
                  (read-char port) ; consume [
                  (if (and (char-ready? port)
                          (char=? (peek-char port) #\2))
                      (begin
                        (read-char port) ; consume 2
                        (read-char port) ; consume 0
                        (read-char port) ; consume 1
                        (read-char port) ; consume ~
                        (%ilog "parse-bracketed-paste: end marker found")
                        #f) ; done
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
    ;; Return as regular text for now - could create paste-msg if needed
    (make <key-msg> #:key 'paste)))
