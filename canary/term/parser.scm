(define-module (canary term parser)
  #:use-module (canary term types)
  #:use-module (canary term ops)
  #:use-module (canary term sgr)
  #:use-module (canary term write)
  #:use-module (canary term utf8)
  #:use-module (rnrs bytevectors)
  #:export (term-process-output!
            term-process-bytes!))

(define (control-byte? ch)
  "Return #t if CH is a C0 control byte (0-31) or DEL (127)."
  (let ((code (char->integer ch)))
    (or (<= code 31)
        (= code 127))))

(define (term-process-output! term str)
  "Feed STR to TERM's emulator one byte at a time, advancing the
parser state machine through ground / ESC / CSI / OSC / DCS modes
and dispatching the resulting control sequences."
  (let ((len (string-length str)))
    (let loop ((idx 0))
      (when (< idx len)
        (let ((state (term-parser-state term)))
          (cond
           ((not state)
            (set! idx (handle-ground term str idx len)))
           ((eq? state 'esc)
            (set! idx (handle-esc term str idx len)))
           ((and (pair? state) (eq? (car state) 'charset))
            (set! idx (handle-charset term str idx len (cadr state))))
           ((eq? state 'csi-fmt)
            (set! idx (handle-csi-fmt term str idx len)))
           ((eq? state 'csi-params)
            (set! idx (handle-csi-params term str idx len)))
           ((eq? state 'csi-fn)
            (set! idx (handle-csi-fn term str idx len)))
           ((eq? state 'osc)
            (set! idx (handle-osc term str idx len)))
           ((eq? state 'dcs)
            (set! idx (handle-dcs term str idx len)))
           (else
            (set-term-parser-state! term #f)
            (set! idx (+ idx 1))))
          (loop idx))))))

(define (handle-ground term str idx len)
  "Parse STR from IDX while in the ground state.  Writes a run of
printable chars in one call to term-write!, then handles the
single control byte that broke the run (BEL / BS / TAB / LF / VT /
FF / CR / SO / SI / ESC).  Returns the new IDX."
  (let ((span-start idx)
        (i idx))
    (let scan ()
      (when (and (< i len)
                 (let ((ch (string-ref str i)))
                   (and (not (control-byte? ch))
                        (not (char=? ch #\esc)))))
        (set! i (+ i 1))
        (scan)))
    (when (> i span-start)
      (term-write! term str span-start i))
    (cond
     ((>= i len) i)
     (else
      (let ((ch (string-ref str i))
            (next-idx (+ i 1)))
        (cond
         ((char=? ch #\alarm)
          (when (term-bell-fn term) ((term-bell-fn term) term))
          next-idx)
         ((char=? ch #\backspace)
          (term-cursor-left! term 1)
          next-idx)
         ((char=? ch #\tab)
          (term-horizontal-tab! term 1)
          next-idx)
         ((char=? ch #\newline)
          (term-line-feed! term)
          next-idx)
         ((or (char=? ch #\vtab) (char=? ch #\page))
          (term-index! term)
          next-idx)
         ((char=? ch #\return)
          (unless (and (< next-idx len)
                       (char=? (string-ref str next-idx) #\newline))
            (term-carriage-return! term))
          next-idx)
         ((char=? ch (integer->char #x0E))
          (set-term-active-charset! term 'g1)
          next-idx)
         ((char=? ch (integer->char #x0F))
          (set-term-active-charset! term 'g0)
          next-idx)
         ((char=? ch #\esc)
          (set-term-parser-state! term 'esc)
          next-idx)
         (else next-idx)))))))

(define (handle-esc term str idx len)
  "Handle the byte after ESC: charset designators, save/restore,
index/reverse-index, CSI/OSC/DCS introducers, full reset, and
charset shifts.  Returns the new IDX."
  (let ((ch (string-ref str idx))
        (next-idx (+ idx 1)))
    (set-term-parser-state! term #f)
    (cond
     ((char=? ch #\() (set-term-parser-state! term '(charset g0)))
     ((char=? ch #\)) (set-term-parser-state! term '(charset g1)))
     ((char=? ch #\*) (set-term-parser-state! term '(charset g2)))
     ((char=? ch #\+) (set-term-parser-state! term '(charset g3)))
     ((char=? ch #\7) (term-save-cursor! term))
     ((char=? ch #\8) (term-restore-cursor! term))
     ((char=? ch #\D) (term-index! term))
     ((char=? ch #\E)
      (term-carriage-return! term)
      (term-line-feed! term))
     ((char=? ch #\M) (term-reverse-index! term))
     ((char=? ch #\[)
      (set-term-parser-state! term 'csi-fmt)
      (set-term-csi-format! term #f)
      (set-term-csi-params! term (list #f)))
     ((char=? ch #\])
      (set-term-parser-state! term 'osc)
      (set-term-osc-buf! term ""))
     ((char=? ch #\P)
      (set-term-parser-state! term 'dcs))
     ((char=? ch #\c) (term-reset! term))
     ((char=? ch #\n) (set-term-active-charset! term 'g2))
     ((char=? ch #\o) (set-term-active-charset! term 'g3))
     (else #f))
    next-idx))

(define (handle-charset term str idx len slot)
  "Designate a charset into SLOT (g0..g3) from the next byte:
'B → us-ascii, '0 → dec-line-drawing; anything else falls back to
us-ascii."
  (let ((ch (string-ref str idx)))
    (set-term-parser-state! term #f)
    (let ((charset (case ch
                     ((#\0) 'dec-line-drawing)
                     ((#\B) 'us-ascii)
                     (else 'us-ascii))))
      (case slot
        ((g0) (set-term-g0! term charset))
        ((g1) (set-term-g1! term charset))
        ((g2) (set-term-g2! term charset))
        ((g3) (set-term-g3! term charset))))
    (+ idx 1)))

(define (handle-csi-fmt term str idx len)
  "Read the optional CSI private-format byte ('?', '>', '=') and
transition to csi-params, or transition directly when no format
byte is present."
  (let ((ch (string-ref str idx)))
    (cond
     ((char=? ch #\?)
      (set-term-csi-format! term #\?)
      (set-term-parser-state! term 'csi-params)
      (+ idx 1))
     ((char=? ch #\>)
      (set-term-csi-format! term #\>)
      (set-term-parser-state! term 'csi-params)
      (+ idx 1))
     ((char=? ch #\=)
      (set-term-csi-format! term #\=)
      (set-term-parser-state! term 'csi-params)
      (+ idx 1))
     (else
      (set-term-csi-format! term #f)
      (set-term-parser-state! term 'csi-params)
      idx))))

(define (handle-csi-params term str idx len)
  "Accumulate CSI parameter bytes (digits, ';' separators, ':'
sub-separators) into TERM's csi-params slot.  On ':' the head
param is promoted to an ordered sublist so SGR extended colour
sequences can carry sub-parameters.  Hands off to csi-fn on
encountering a non-param byte."
  (let ((ch (string-ref str idx)))
    (cond
     ((and (char>=? ch #\0) (char<=? ch #\9))
      (let* ((digit (- (char->integer ch) (char->integer #\0)))
             (params (term-csi-params term))
             (head (car params))
             (rest (cdr params))
             (new-head (+ (* (or head 0) 10) digit)))
        (set-term-csi-params! term (cons new-head rest))
        (+ idx 1)))
     ((char=? ch #\;)
      (set-term-csi-params! term (cons #f (term-csi-params term)))
      (+ idx 1))
     ((char=? ch #\:)
      (let* ((params (term-csi-params term))
             (head (car params))
             (rest (cdr params)))
        (cond
         ((pair? head)
          (set-term-csi-params! term (cons (append head (list #f)) rest)))
         (else
          (set-term-csi-params! term (cons (list head #f) rest))))
        (+ idx 1)))
     (else
      (set-term-parser-state! term 'csi-fn)
      idx))))

(define (handle-csi-fn term str idx len)
  "Read the CSI final byte (range @..~), dispatch the CSI to its
handler, and return to ground state."
  (let ((ch (string-ref str idx)))
    (cond
     ((and (char>=? ch #\@) (char<=? ch #\~))
      (set-term-parser-state! term #f)
      (let ((params (reverse (term-csi-params term)))
            (fmt (term-csi-format term)))
        (dispatch-csi term ch fmt params))
      (+ idx 1))
     (else (+ idx 1)))))

(define (handle-osc term str idx len)
  "Accumulate an OSC payload until ST (BEL or ESC\\) terminates it,
then dispatch.  Strips the trailing ESC when the terminator is the
two-byte form."
  (let scan ((i idx))
    (cond
     ((= i len)
      (set-term-osc-buf!
       term (string-append (term-osc-buf term) (substring str idx i)))
      i)
     ((or (char=? (string-ref str i) #\alarm)
          (char=? (string-ref str i) #\\))
      (let ((chunk (substring str idx i)))
        (set-term-osc-buf! term (string-append (term-osc-buf term) chunk))
        (cond
         ((and (char=? (string-ref str i) #\\)
               (positive? (string-length (term-osc-buf term)))
               (char=? (string-ref (term-osc-buf term)
                                   (- (string-length (term-osc-buf term)) 1))
                       #\esc))
          (set-term-osc-buf!
           term (substring (term-osc-buf term) 0
                        (- (string-length (term-osc-buf term)) 1))))
         (else #t))
        (dispatch-osc term (term-osc-buf term))
        (set-term-parser-state! term #f)
        (set-term-osc-buf! term "")
        (+ i 1)))
     (else (scan (+ i 1))))))

(define (handle-dcs term str idx len)
  "Skip a DCS (Device Control String) payload up to and including
its ESC\\ ST terminator.  The contents are discarded; canary
doesn't honour any DCS sequences yet."
  (let scan ((i idx))
    (cond
     ((>= i len) len)
     ((and (char=? (string-ref str i) #\esc)
           (< (+ i 1) len)
           (char=? (string-ref str (+ i 1)) #\\))
      (set-term-parser-state! term #f)
      (+ i 2))
     (else (scan (+ i 1))))))

(define (dispatch-csi term ch fmt params)
  "Dispatch a CSI ending in final byte CH with private FMT byte
(or #f) and decoded PARAMS list to the appropriate term op.  Covers
cursor movement, line/char insert/delete, erase, scroll, SGR, set
modes, scroll region, save/restore cursor, device queries."
  (let ((p1 (and (pair? params) (car params)))
        (p2 (and (pair? params) (pair? (cdr params)) (cadr params))))
    (define (or1 v) (or v 1))
    (define (or0 v) (or v 0))
    (cond
     ((char=? ch #\@) (term-insert-char! term (or1 p1)))
     ((or (char=? ch #\A) (char=? ch #\k)) (term-cursor-up! term (or1 p1)))
     ((or (char=? ch #\B) (char=? ch #\e)) (term-cursor-down! term (or1 p1)))
     ((or (char=? ch #\C) (char=? ch #\a)) (term-cursor-right! term (or1 p1)))
     ((or (char=? ch #\D) (char=? ch #\j)) (term-cursor-left! term (or1 p1)))
     ((char=? ch #\E)
      (term-cursor-down! term (or1 p1))
      (term-carriage-return! term))
     ((char=? ch #\F)
      (term-cursor-up! term (or1 p1))
      (term-carriage-return! term))
     ((or (char=? ch #\G) (char=? ch #\`))
      (term-cursor-horizontal-abs! term (or1 p1)))
     ((or (char=? ch #\H) (char=? ch #\f))
      (term-goto! term (or1 p1) (or1 p2)))
     ((char=? ch #\I) (term-horizontal-tab! term (or1 p1)))
     ((char=? ch #\J) (term-erase-in-display! term (or0 p1)))
     ((char=? ch #\K) (term-erase-in-line! term (or0 p1)))
     ((char=? ch #\L) (term-insert-line! term (or1 p1)))
     ((char=? ch #\M) (term-delete-line! term (or1 p1)))
     ((char=? ch #\P) (term-delete-char! term (or1 p1)))
     ((char=? ch #\S)
      (unless (eqv? fmt #\?)
        (term-scroll-up! term (or1 p1))))
     ((char=? ch #\T) (term-scroll-down! term (or1 p1)))
     ((char=? ch #\X) (term-erase-char! term (or1 p1)))
     ((char=? ch #\Z) (term-horizontal-backtab! term (or1 p1)))
     ((char=? ch #\b)
      (let ((n (or1 p1))
            (last (term-last-char term)))
        (when (and (char? last)
                   (let ((c (char->integer last)))
                     (and (>= c 32) (not (= c 127)))))
          (term-write! term (make-string n last)))))
     ((char=? ch #\c) (dispatch-device-attrs term (or0 p1) fmt))
     ((char=? ch #\d) (term-cursor-vertical-abs! term (or1 p1)))
     ((char=? ch #\h) (dispatch-set-modes term params fmt #t))
     ((char=? ch #\l) (dispatch-set-modes term params fmt #f))
     ((char=? ch #\m)
      (unless fmt (process-sgr! term params)))
     ((char=? ch #\n) (dispatch-device-status term (or0 p1)))
     ((char=? ch #\q)
      (when (and (>= (length params) 1) (not fmt))
        (dispatch-cursor-style term (or0 p1))))
     ((char=? ch #\r) (term-set-scroll-region! term p1 p2))
     ((char=? ch #\s) (when (not fmt) (term-save-cursor! term)))
     ((char=? ch #\u) (when (not fmt) (term-restore-cursor! term)))
     (else #f))))

(define (dispatch-device-attrs term n fmt)
  "Reply to a Device Attributes (DA1 / DA2) query via TERM's
input-fn, identifying as a VT102-class terminal."
  (when (term-input-fn term)
    (cond
     ((not fmt)
      (when (zero? n)
        ((term-input-fn term) term (string #\esc #\[ #\? #\1 #\2 #\; #\4 #\c))))
     ((eqv? fmt #\>)
      (when (zero? n)
        ((term-input-fn term) term (string #\esc #\[ #\> #\0 #\; #\0 #\; #\0 #\c)))))))

(define (dispatch-device-status term n)
  "Reply to a Device Status Report query via TERM's input-fn.
N=5 → \"OK\" report; N=6 → cursor position report."
  (when (term-input-fn term)
    (case n
      ((5) ((term-input-fn term) term (string #\esc #\[ #\0 #\n)))
      ((6) ((term-input-fn term) t
             (string-append (string #\esc) "["
                            (number->string (+ 1 (term-cursor-y term)))
                            ";"
                            (number->string (+ 1 (term-cursor-x term)))
                            "R"))))))

(define *cursor-styles*
  #(blinking-block blinking-block block
    blinking-underline underline
    blinking-bar bar))

(define (dispatch-cursor-style term style)
  "Set TERM's cursor style from the DECSCUSR numeric STYLE (0-6,
mapped to the blink/steady block/underline/bar variants)."
  (when (and (>= style 0) (<= style 6))
    (set-term-cursor-style! term (vector-ref *cursor-styles* style))))

(define (dispatch-set-modes term params fmt set?)
  "Apply CSI h/l mode-set/reset for each parameter in PARAMS.
FMT distinguishes ANSI modes (#f, e.g. insert mode 4) from DEC
private modes (#\\?, e.g. cursor visibility, alt-screen, bracketed
paste).  SET? is #t for h (set), #f for l (reset)."
  (for-each
   (lambda (p)
     (when p
       (cond
        ((not fmt)
         (case p
           ((4) (set-term-insert! term set?))))
        ((eqv? fmt #\?)
         (case p
           ((1) (set-term-keypad! term set?))
           ((7) (set-term-auto-margin! term set?))
           ((12)
            (cond
             (set?
              (case (term-cursor-style term)
                ((block) (set-term-cursor-style! term 'blinking-block))
                ((underline) (set-term-cursor-style! term 'blinking-underline))
                ((bar) (set-term-cursor-style! term 'blinking-bar))))
             (else
              (case (term-cursor-style term)
                ((blinking-block) (set-term-cursor-style! term 'block))
                ((blinking-underline) (set-term-cursor-style! term 'underline))
                ((blinking-bar) (set-term-cursor-style! term 'bar))))))
           ((25) (set-term-cursor-visible! term set?))
           ((1047)
            (if set? (term-enter-alt-screen! term)
                     (term-exit-alt-screen! term)))
           ((1048)
            (if set? (term-save-cursor! term)
                     (term-restore-cursor! term)))
           ((1049)
            (cond
             (set? (term-save-cursor! term) (term-enter-alt-screen! term))
             (else (term-exit-alt-screen! term) (term-restore-cursor! term))))
           ((2004) (set-term-bracketed-paste! term set?)))))))
   params))

(define (dispatch-osc term s)
  "Dispatch an OSC payload S (already stripped of introducer and
terminator) by its leading numeric code: 0/2 set the window title,
7 sets the cwd, 10/11 reply to fg/bg colour queries."
  (let ((semi (string-index s #\;)))
    (when semi
      (let ((code (substring s 0 semi))
            (data (substring s (+ semi 1))))
        (cond
         ((or (string=? code "0") (string=? code "2"))
          (set-term-title! term data)
          (when (term-title-fn term) ((term-title-fn term) term data)))
         ((string=? code "7")
          (set-term-cwd! term data)
          (when (term-cwd-fn term) ((term-cwd-fn term) term data)))
         ((string=? code "10")
          (when (and (string=? data "?") (term-input-fn term))
            ((term-input-fn term) t
             (string-append (string #\esc) "]10;rgb:d8d8/d8d8/d8d8"
                            (string #\esc) "\\"))))
         ((string=? code "11")
          (when (and (string=? data "?") (term-input-fn term))
            ((term-input-fn term) t
             (string-append (string #\esc) "]11;rgb:1818/1818/1818"
                            (string #\esc) "\\")))))))))

(define (string-index s ch)
  "Return the index of the first occurrence of CH in S, or #f."
  (let ((len (string-length s)))
    (let loop ((i 0))
      (cond
       ((= i len) #f)
       ((char=? (string-ref s i) ch) i)
       (else (loop (+ i 1)))))))

(define* (term-process-bytes! term decoder bv #:optional (start 0) (end #f))
  "Decode bytes [START, END) of bytevector BV through DECODER, a
<utf8-decoder>, and feed the resulting characters through TERM's
parser.  DECODER carries partial multi-byte codepoint state across
calls; supply the same DECODER for each chunk of one byte stream.
Returns unspecified."
  (let ((chunk (utf8-decode-bytes! decoder bv start end)))
    (term-process-output! term chunk)))
