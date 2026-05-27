(define-module (canary backend-ansi)
  #:use-module (canary backend)
  #:use-module (canary draw)
  #:use-module (canary faces)
  #:use-module (canary theme)
  #:use-module (canary protocol)
  #:use-module (canary terminal)
  #:use-module ((canary render) #:select (image-cmd->fallback-cmds))
  #:use-module ((canary image)  #:select (image-bytes image-registered?))
  #:use-module ((canary term types) #:prefix t:)
  #:use-module ((canary term ops) #:prefix t:)
  #:use-module ((canary term write) #:prefix t:)
  #:use-module ((canary term render) #:prefix t:)
  #:use-module (oop goops)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module ((srfi srfi-13) #:select (string-contains string-index))
  #:export (<ansi-backend>
            ansi-backend
            ansi-backend-theme
            set-ansi-backend-theme!
            ansi-backend-port
            ansi-backend-cur-term
            ansi-backend-prev-term
            ansi-backend-size
            graphics?
            cell-w
            cell-h
            face->sgr
            cmds->ansi
            render-cmds-to-term!
            request-window-size!
            stats
            reset-stats!))

(define-class <ansi-backend> (<backend>)
  (port      #:init-keyword #:port  #:accessor ansi-backend-port)
  (theme     #:init-keyword #:theme #:accessor ansi-backend-theme)
  (size      #:init-keyword #:size  #:init-value (size 80 24) #:accessor ansi-backend-size)
  (cur-term  #:init-value #f #:accessor ansi-backend-cur-term)
  (prev-term #:init-value #f #:accessor ansi-backend-prev-term)
  (graphics?         #:init-value #f             #:accessor graphics?)
  (cell-w            #:init-value 10             #:accessor cell-w)
  (cell-h            #:init-value 20             #:accessor cell-h)
  (image-ids         #:init-form (make-hash-table) #:accessor ansi-backend-image-ids)
  (next-image-id     #:init-value 1              #:accessor ansi-backend-next-image-id)
  (placements        #:init-form (make-hash-table) #:accessor ansi-backend-placements)
  (next-placement-id #:init-value 1              #:accessor ansi-backend-next-placement-id)
  ;; metrics (since last reset)
  (frames                  #:init-value 0 #:accessor ansi-backend-frames)
  (bytes-out               #:init-value 0 #:accessor ansi-backend-bytes-out)
  (sgr-transitions         #:init-value 0 #:accessor ansi-backend-sgr-transitions)
  (cursor-moves            #:init-value 0 #:accessor ansi-backend-cursor-moves)
  (image-transmits         #:init-value 0 #:accessor ansi-backend-image-transmits)
  (image-transmit-bytes    #:init-value 0 #:accessor ansi-backend-image-transmit-bytes)
  (placements-placed       #:init-value 0 #:accessor ansi-backend-placements-placed)
  (placements-deleted      #:init-value 0 #:accessor ansi-backend-placements-deleted))

(define (set-ansi-backend-theme! b th)
  "Replace the theme on backend B with TH."
  (set! (ansi-backend-theme b) th))

(define* (ansi-backend #:key (port (current-output-port))
                            (theme default-theme))
  "Return a fresh <ansi-backend> writing to PORT (defaults to
current-output-port) under THEME (defaults to default-theme)."
  (make <ansi-backend> #:port port #:theme theme))

(define (hex->rgb hex)
  "Parse an HTML color string like \"#ff00aa\" or \"ff00aa\" into a
three-element list (R G B) of integers 0-255.  Returns white when
the string isn't 6 hex digits."
  (let ((h (if (and (>= (string-length hex) 1)
                    (char=? (string-ref hex 0) #\#))
               (substring hex 1) hex)))
    (cond
     ((= (string-length h) 6)
      (list (string->number (substring h 0 2) 16)
            (string->number (substring h 2 4) 16)
            (string->number (substring h 4 6) 16)))
     (else '(255 255 255)))))

(define (sgr-fg-rgb hex)
  "Return the SGR parameter string for a true-color foreground given
HEX (e.g. \"38;2;255;0;170\")."
  (let ((rgb (hex->rgb hex)))
    (string-append "38;2;" (number->string (car rgb)) ";"
                   (number->string (cadr rgb)) ";"
                   (number->string (caddr rgb)))))

(define (sgr-bg-rgb hex)
  "Return the SGR parameter string for a true-color background given
HEX (e.g. \"48;2;255;0;170\")."
  (let ((rgb (hex->rgb hex)))
    (string-append "48;2;" (number->string (car rgb)) ";"
                   (number->string (cadr rgb)) ";"
                   (number->string (caddr rgb)))))

(define (attr->sgr a)
  "Return the SGR numeric parameter for an attribute symbol A
(bold/dim/italic/underline/blink/reverse/strikethrough), or #f if A
isn't a recognised attribute."
  (case a
    ((bold) "1") ((dim) "2") ((italic) "3") ((underline) "4")
    ((blink) "5") ((reverse) "7") ((strikethrough) "9")
    (else #f)))

(define (face->sgr face extra-attrs)
  "Return the full ESC[…m SGR sequence representing FACE plus
EXTRA-ATTRS (a list of attribute symbols to union into face's own
attrs).  Returns a reset (ESC[0m) when FACE is #f or carries no
visible state."
  (cond
   ((not face) "\x1b[0m")
   (else
    (let* ((parts '())
           (attrs (append (or (face-attrs face) '()) (or extra-attrs '())))
           (parts (fold (lambda (a acc)
                          (let ((s (attr->sgr a)))
                            (if s (cons s acc) acc)))
                        parts attrs))
           (parts (if (face-fg face) (cons (sgr-fg-rgb (face-fg face)) parts) parts))
           (parts (if (face-bg face) (cons (sgr-bg-rgb (face-bg face)) parts) parts)))
      (cond
       ((null? parts) "\x1b[0m")
       (else (string-append "\x1b[" (string-join parts ";" 'infix) "m")))))))

(define (resolve-color v th)
  "Resolve a face color slot V against theme TH.  A string passes
through as-is, a symbol is looked up in the active palette, anything
else returns #f."
  (cond
   ((string? v) v)
   ((symbol? v) (theme-resolve th v))
   (else #f)))

(define (normalize-face f)
  "Faces on cmds can be the symbol 'default or a <face> record. Return
either a <face> record or #f for 'default."
  (cond ((face? f) f) (else #f)))

(define (apply-face-to-term-attrs! tattrs face extra-attrs th)
  "Mutate term attribute slot TATTRS in place to reflect FACE
(resolved against theme TH) plus EXTRA-ATTRS.  Resets the SGR slots
first so old attrs don't bleed into the new cell; the hyperlink
slot is taken from FACE directly."
  (t:reset-face-attrs! tattrs)
  (t:set-face-hyperlink! tattrs (and face (face-hyperlink face)))
  (t:set-face-semantic!  tattrs (and face (face-semantic face)))
  (when face
    (let ((fg (resolve-color (face-fg face) th))
          (bg (resolve-color (face-bg face) th)))
      (when fg (t:set-face-fg! tattrs (hex->rgb fg)))
      (when bg (t:set-face-bg! tattrs (hex->rgb bg))))
    (for-each
     (lambda (a)
       (case a
         ((bold) (t:set-face-bold! tattrs #t))
         ((dim faint) (t:set-face-faint! tattrs #t))
         ((italic) (t:set-face-italic! tattrs #t))
         ((underline) (t:set-face-underline! tattrs 'single))
         ((blink) (t:set-face-blink! tattrs 'slow))
         ((reverse) (t:set-face-inverse! tattrs #t))
         ((strikethrough) (t:set-face-crossed! tattrs #t))
         ((overline) (t:set-face-overline! tattrs #t))))
     (append (or (face-attrs face) '()) (or extra-attrs '())))))

(define (blit-cells-to-term! term col row w h src-chars src-faces)
  "Copy a W×H block from SRC-CHARS / SRC-FACES (row-major, length
W*H) into TERM starting at (COL, ROW).  Bulk version of
set-term-cell-at! avoiding per-cell goto/write overhead — used by
cells-cmd."
  (let* ((tw         (t:term-width term))
         (th         (t:term-height term))
         (dst-chars  (t:term-chars term))
         (dst-faces  (t:term-faces term))
         ;; Clip to term bounds in case the block doesn't fit.
         (clipped-w  (min w (max 0 (- tw col))))
         (clipped-h  (min h (max 0 (- th row)))))
    (do ((dy 0 (+ dy 1))) ((>= dy clipped-h))
      (let ((src-base (* dy w))
            (dst-base (+ (* (+ row dy) tw) col)))
        (do ((dx 0 (+ dx 1))) ((>= dx clipped-w))
          (u32vector-set! dst-chars (+ dst-base dx)
                          (u32vector-ref src-chars (+ src-base dx)))
          (vector-set! dst-faces (+ dst-base dx)
                       (vector-ref src-faces (+ src-base dx))))))))

(define (render-cmds-to-term! term cmds th)
  "Apply each draw cmd in CMDS to TERM, resolving faces against
theme TH.  Handles clear, text, fill, cursor, and image cmds; image
cmds use the registered fallback if graphics support is off."
  (for-each
   (lambda (cmd)
     (cond
      ((clear-cmd? cmd)
       (t:reset-face-attrs! (t:term-attrs term))
       (t:term-erase-in-display! term 2)
       (t:term-goto! term 1 1))
      ((text-cmd? cmd)
       (apply-face-to-term-attrs! (t:term-attrs term)
                                  (normalize-face (text-face cmd))
                                  (text-attrs cmd) th)
       (t:term-goto! term (+ (text-row cmd) 1) (+ (text-col cmd) 1))
       (t:term-write! term (text-str cmd)))
      ((cells-cmd? cmd)
       ;; Bulk-blit a pre-rendered W×H char/face block straight into
       ;; the term grid.  Bypasses the per-cell text-cmd → term-goto!
       ;; → term-write! pipeline that costs ~5 µs per cell; here each
       ;; cell is one u32vector-set! + one vector-set!, ~50 ns.  Used
       ;; by dense rectangular content like delve's map viewport.
       (blit-cells-to-term! term
                            (cells-col cmd) (cells-row cmd)
                            (cells-w cmd)   (cells-h cmd)
                            (cells-chars cmd) (cells-faces cmd)))
      ((fill-cmd? cmd)
       (let* ((w (fill-w cmd))
              (h (fill-h cmd))
              (line (make-string w #\space)))
         (apply-face-to-term-attrs! (t:term-attrs term)
                                    (normalize-face (fill-face cmd))
                                    '() th)
         (do ((r 0 (+ r 1)))
             ((= r h))
           (t:term-goto! term (+ (fill-row cmd) r 1) (+ (fill-col cmd) 1))
           (t:term-write! term line))))
      ((cursor-cmd? cmd)
       (t:term-goto! term (+ (cursor-row cmd) 1) (+ (cursor-col cmd) 1)))
      ((image-cmd? cmd)
       (render-cmds-to-term! term (image-cmd->fallback-cmds cmd) th))
      (else #f)))
   cmds))

;; Placement vector layout:
;;   #(placement-id img-id src src-x src-y src-w src-h w h px py)
;;        0          1     2   3     4     5     6    7 8 9  10

(define (pos-key col row)
  "Encode a (COL, ROW) cell origin into a single integer key for
hash lookups.  Inverse of `key->col` / `key->row`.  Assumes COL <
100000."
  (+ (* row 100000) col))

(define (key->col k)
  "Decode the column from a position key produced by `pos-key`."
  (modulo k 100000))

(define (key->row k)
  "Decode the row from a position key produced by `pos-key`."
  (quotient k 100000))

(define (placement-content-eq? a b)
  "Return #t if placement vectors A and B describe the same image
content (same img-id, src/dst rectangle, and pixel offsets).
Placement ids are not compared."
  (and (= (vector-ref a 1)  (vector-ref b 1))
       (= (vector-ref a 3)  (vector-ref b 3))
       (= (vector-ref a 4)  (vector-ref b 4))
       (= (vector-ref a 5)  (vector-ref b 5))
       (= (vector-ref a 6)  (vector-ref b 6))
       (= (vector-ref a 7)  (vector-ref b 7))
       (= (vector-ref a 8)  (vector-ref b 8))
       (= (vector-ref a 9)  (vector-ref b 9))
       (= (vector-ref a 10) (vector-ref b 10))))

(define (emit-images! b port cmds)
  "Position-keyed diff. Each (col,row) origin is one placement slot.
Deletes for slots that vanished; places for new or content-changed
slots. Unchanged slots: zero bytes.  All escape sequences are written
to PORT — typically the frame-assembly string port from backend-draw,
so a frame with graphics still ships as one write."
  (let* ((old  (ansi-backend-placements b))
         (new  (make-hash-table)))
    ;; Resolve img-ids first so unregistered srcs drop out before the diff.
    (for-each
     (lambda (c)
       (let* ((src    (image-src c))
              (img-id (image-id-for! b port src)))
         (when img-id
           (hash-set! new (pos-key (image-col c) (image-row c))
                      (vector #f img-id src
                              (image-src-x c) (image-src-y c)
                              (image-src-w c) (image-src-h c)
                              (image-w   c)   (image-h   c)
                              (image-px  c)   (image-py  c))))))
     cmds)
    (hash-for-each
     (lambda (key old-vec)
       (unless (hash-ref new key)
         (emit-image-delete-placement! port
                                       (vector-ref old-vec 1)
                                       (vector-ref old-vec 0))
         (set! (ansi-backend-placements-deleted b)
               (+ (ansi-backend-placements-deleted b) 1))))
     old)
    (hash-for-each
     (lambda (key new-vec)
       (let ((old-vec (hash-ref old key)))
         (cond
          ((and old-vec (placement-content-eq? old-vec new-vec))
           (vector-set! new-vec 0 (vector-ref old-vec 0)))
          (else
           (when (and old-vec
                      (not (= (vector-ref old-vec 1) (vector-ref new-vec 1))))
             (emit-image-delete-placement! port
                                           (vector-ref old-vec 1)
                                           (vector-ref old-vec 0))
             (set! (ansi-backend-placements-deleted b)
                   (+ (ansi-backend-placements-deleted b) 1)))
           (let ((pid (if old-vec
                          (vector-ref old-vec 0)
                          (next-placement-id! b))))
             (vector-set! new-vec 0 pid)
             (emit-image-place! port
                                (vector-ref new-vec 1) pid
                                (key->col key) (key->row key)
                                (vector-ref new-vec 7) (vector-ref new-vec 8)
                                (vector-ref new-vec 3) (vector-ref new-vec 4)
                                (vector-ref new-vec 5) (vector-ref new-vec 6)
                                (vector-ref new-vec 9) (vector-ref new-vec 10))
             (set! (ansi-backend-placements-placed b)
                   (+ (ansi-backend-placements-placed b) 1)))))))
     new)
    (set! (ansi-backend-placements b) new)))

(define (split-cmds-for-graphics b cmds)
  "When graphics? is on, partition image-cmds with a registered src into
the graphics list, leaving everything else (text/fill/cursor/clear, and
image-cmds with unregistered srcs) in the term-grid list. With graphics?
off, all image-cmds stay in the term-grid list and render as fallback."
  (cond
   ((not (graphics? b)) (values '() cmds))
   (else
    (let lp ((cs cmds) (gfx '()) (rest '()))
      (cond
       ((null? cs) (values (reverse gfx) (reverse rest)))
       ((and (image-cmd? (car cs))
             (image-registered? (image-src (car cs))))
        (lp (cdr cs) (cons (car cs) gfx) rest))
       (else (lp (cdr cs) gfx (cons (car cs) rest))))))))

(define (cmds-extent cmds)
  "Return a (W . H) cons giving the smallest grid size that contains
every text, fill, and cursor cmd in CMDS.  Image cmds are ignored."
  (let lp ((cs cmds) (mw 1) (mh 1))
    (cond
     ((null? cs) (cons mw mh))
     (else
      (let ((c (car cs)))
        (cond
         ((text-cmd? c)
          (lp (cdr cs)
              (max mw (+ (text-col c) (string-length (text-str c))))
              (max mh (+ (text-row c) 1))))
         ((fill-cmd? c)
          (lp (cdr cs)
              (max mw (+ (fill-col c) (fill-w c)))
              (max mh (+ (fill-row c) (fill-h c)))))
         ((cursor-cmd? c)
          (lp (cdr cs)
              (max mw (+ (cursor-col c) 1))
              (max mh (+ (cursor-row c) 1))))
         (else (lp (cdr cs) mw mh))))))))

(define* (cmds->ansi cmds th #:key cols rows)
  "Render CMDS as a full-frame ANSI string under theme TH.  COLS and
ROWS override the autodetected extent.  Uses a fresh term grid as
the diff baseline, so the output is a complete repaint, not a diff."
  (let* ((ext (cmds-extent cmds))
         (w (or cols (car ext)))
         (h (or rows (cdr ext)))
         (term (t:make-term #:width w #:height h)))
    (render-cmds-to-term! term cmds th)
    (t:term-diff->ansi #f term)))

(define +sync-begin+ "\x1b[?2026h")
(define +sync-end+ "\x1b[?2026l")

(define %b64-alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (base64-encode bv)
  "Return the standard-alphabet base64 encoding of bytevector BV as
a string.  Trailing input chunks are zero-padded internally and the
output is `=`-padded to a multiple of four characters."
  (let* ((n   (bytevector-length bv))
         (out (make-string (* 4 (quotient (+ n 2) 3)) #\=)))
    (let loop ((i 0) (j 0))
      (cond
       ((>= i n) out)
       (else
        (let* ((b0 (bytevector-u8-ref bv i))
               (b1 (if (< (+ i 1) n) (bytevector-u8-ref bv (+ i 1)) 0))
               (b2 (if (< (+ i 2) n) (bytevector-u8-ref bv (+ i 2)) 0))
               (k0 (ash b0 -2))
               (k1 (logior (logand (ash b0 4) #x30) (ash b1 -4)))
               (k2 (logior (logand (ash b1 2) #x3c) (ash b2 -6)))
               (k3 (logand b2 #x3f)))
          (string-set! out j       (string-ref %b64-alphabet k0))
          (string-set! out (+ j 1) (string-ref %b64-alphabet k1))
          (when (< (+ i 1) n)
            (string-set! out (+ j 2) (string-ref %b64-alphabet k2)))
          (when (< (+ i 2) n)
            (string-set! out (+ j 3) (string-ref %b64-alphabet k3)))
          (loop (+ i 3) (+ j 4))))))))

(define +chunk-size+ 3072)   ; pre-base64; b64 expansion ≤ 4096 limit

(define (emit-image-transmit! port id bv)
  "Send a kitty graphics-protocol transmit (a=t) command to PORT
for image ID with payload BV.  Splits BV across chunks so each
emitted frame is ≤4096 bytes of base64 (the kitty per-frame limit)."
  (let* ((b64 (base64-encode bv))
         (n   (string-length b64)))
    (let loop ((off 0))
      (let* ((remain (- n off))
             (size   (min +chunk-size+ remain))
             (more?  (> remain size))
             (head   (if (zero? off)
                         (string-append "a=t,f=100,i=" (number->string id)
                                        ",m=" (if more? "1" "0"))
                         (string-append "m=" (if more? "1" "0")))))
        (display "\x1b_G" port)
        (display head port)
        (display ";" port)
        (display (substring b64 off (+ off size)) port)
        (display "\x1b\\" port)
        (when more? (loop (+ off size)))))))

(define (emit-image-place! port img-id pid col row w h sx sy sw sh px py)
  "Send a kitty graphics place (a=p) command to PORT: position the
cursor at (COL, ROW), then place IMG-ID's already-transmitted image
as placement PID into a W-cells × H-cells slot, optionally cropped
to source rectangle (SX, SY, SW, SH) and offset within the cell by
(PX, PY) pixels."
  (display "\x1b[" port)
  (display (number->string (+ row 1)) port)
  (display ";" port)
  (display (number->string (+ col 1)) port)
  (display "H" port)
  (display "\x1b_Ga=p,i=" port)
  (display (number->string img-id) port)
  (display ",p=" port)
  (display (number->string pid) port)
  (display ",c=" port)
  (display (number->string w) port)
  (display ",r=" port)
  (display (number->string h) port)
  (when (and (positive? sw) (positive? sh))
    (display ",x=" port) (display (number->string sx) port)
    (display ",y=" port) (display (number->string sy) port)
    (display ",w=" port) (display (number->string sw) port)
    (display ",h=" port) (display (number->string sh) port))
  (when (positive? px)
    (display ",X=" port) (display (number->string px) port))
  (when (positive? py)
    (display ",Y=" port) (display (number->string py) port))
  (display ",z=1\x1b\\" port))

(define (emit-image-delete-placement! port img-id pid)
  "Send a kitty graphics delete-placement (a=d, d=i) command to
PORT, removing placement PID of image IMG-ID."
  (display "\x1b_Ga=d,d=i,i=" port)
  (display (number->string img-id) port)
  (display ",p=" port)
  (display (number->string pid) port)
  (display "\x1b\\" port))

(define (next-placement-id! b)
  "Allocate and return the next unused placement id on backend B,
advancing the counter."
  (let ((id (ansi-backend-next-placement-id b)))
    (set! (ansi-backend-next-placement-id b) (+ id 1))
    id))

(define (image-id-for! b out src)
  "Return the kitty image id for SRC, transmitting the bytes to OUT on
first use.  Returns #f if SRC isn't registered.  OUT is the frame-
assembly port (so a transmit + place sequence ships atomically with
the rest of the frame)."
  (cond
   ((hashq-ref (ansi-backend-image-ids b) src) => (lambda (id) id))
   ((not (image-registered? src)) #f)
   (else
    (let* ((id (ansi-backend-next-image-id b))
           (bv (image-bytes src)))
      (emit-image-transmit! out id bv)
      (hashq-set! (ansi-backend-image-ids b) src id)
      (set! (ansi-backend-next-image-id b) (+ id 1))
      (set! (ansi-backend-image-transmits b)
            (+ (ansi-backend-image-transmits b) 1))
      (set! (ansi-backend-image-transmit-bytes b)
            (+ (ansi-backend-image-transmit-bytes b)
               ;; PNG payload base64-expanded (~4/3) + framing overhead per chunk
               (quotient (* (bytevector-length bv) 4) 3)
               (* 40 (max 1 (quotient (bytevector-length bv) 3072)))))
      id))))

(define (partition-image-cmds cmds)
  "Return two values: the image cmds from CMDS (in input order) and
everything else (also in input order)."
  (let lp ((cs cmds) (gfx '()) (rest '()))
    (cond
     ((null? cs) (values (reverse gfx) (reverse rest)))
     ((image-cmd? (car cs)) (lp (cdr cs) (cons (car cs) gfx) rest))
     (else (lp (cdr cs) gfx (cons (car cs) rest))))))

(define (parse-cell-size response)
  "Pull height,width out of a \\e[6;H;Wt response if present.
Returns (values H W) or (values #f #f) if absent."
  (let ((hit (string-contains response "\x1b[6;")))
    (cond
     ((not hit) (values #f #f))
     (else
      (let* ((rest (substring response (+ hit 4)))
             (tend (string-index rest #\t)))
        (cond
         ((not tend) (values #f #f))
         (else
          (let* ((body  (substring rest 0 tend))
                 (parts (string-split body #\;)))
            (cond
             ((not (= (length parts) 2)) (values #f #f))
             (else
              (let ((h (string->number (car  parts)))
                    (w (string->number (cadr parts))))
                (if (and h w (positive? h) (positive? w))
                    (values h w)
                    (values #f #f)))))))))))))

(define (detect-kitty-graphics! b)
  "Send a kitty graphics capability probe, a cell-pixel-size query
\\e[16t, and DA1. Read the response with a short timeout. Set the
backend's cell-w/cell-h slots from the response. Return #t iff the
terminal answered the kitty query with OK."
  (let ((out (ansi-backend-port b))
        (in  (current-input-port)))
    (display "\x1b_Gi=1,a=q;AAAA\x1b\\\x1b[16t\x1b[c" out)
    (force-output out)
    (let* ((deadline-ms 250)
           (start (get-internal-real-time))
           (units internal-time-units-per-second))
      (let loop ((buf '()) (saw-c? #f))
        (cond
         (saw-c?
          (let ((s (list->string (reverse buf))))
            (call-with-values (lambda () (parse-cell-size s))
              (lambda (h w)
                (when (and h w)
                  (set! (cell-h b) h)
                  (set! (cell-w b) w))))
            (and (string-contains s "_G")
                 (string-contains s "OK"))))
         ((char-ready? in)
          (let ((ch (read-char in)))
            (loop (cons ch buf) (eqv? ch #\c))))
         (else
          (let ((elapsed-ms (quotient (* (- (get-internal-real-time) start) 1000)
                                       units)))
            (if (>= elapsed-ms deadline-ms)
                (let ((s (list->string (reverse buf))))
                  (call-with-values (lambda () (parse-cell-size s))
                    (lambda (h w)
                      (when (and h w)
                        (set! (cell-h b) h)
                        (set! (cell-w b) w))))
                  (and (string-contains s "_G")
                       (string-contains s "OK")))
                (begin (usleep 1000) (loop buf #f))))))))))

(define (count-csi-escapes s)
  "Scan S for CSI sequences (\\e[…<final>). Return (values sgr cursor),
counting m-terminated and H-terminated sequences respectively."
  (let ((n (string-length s)))
    (let loop ((i 0) (sgr 0) (cur 0))
      (cond
       ((>= i n) (values sgr cur))
       ((and (char=? (string-ref s i) #\esc)
             (< (+ i 1) n)
             (char=? (string-ref s (+ i 1)) #\[))
        (let scan ((j (+ i 2)))
          (cond
           ((>= j n) (values sgr cur))
           (else
            (let ((c (string-ref s j)))
              (cond
               ((char=? c #\m) (loop (+ j 1) (+ sgr 1) cur))
               ((char=? c #\H) (loop (+ j 1) sgr (+ cur 1)))
               ((and (char>=? c #\@) (char<=? c #\~))
                (loop (+ j 1) sgr cur))
               (else (scan (+ j 1)))))))))
       (else (loop (+ i 1) sgr cur))))))

(define (stats b)
  "Return an alist of metrics counters for B since last reset-stats!."
  (let ((f (ansi-backend-frames b))
        (bo (ansi-backend-bytes-out b)))
    `((frames               . ,f)
      (bytes-out            . ,bo)
      (bytes-per-frame      . ,(if (zero? f) 0 (exact->inexact (/ bo f))))
      (sgr-transitions      . ,(ansi-backend-sgr-transitions b))
      (cursor-moves         . ,(ansi-backend-cursor-moves b))
      (image-transmits      . ,(ansi-backend-image-transmits b))
      (image-transmit-bytes . ,(ansi-backend-image-transmit-bytes b))
      (placements-placed    . ,(ansi-backend-placements-placed b))
      (placements-deleted   . ,(ansi-backend-placements-deleted b)))))

(define (reset-stats! b)
  "Zero all metrics counters on B."
  (set! (ansi-backend-frames b) 0)
  (set! (ansi-backend-bytes-out b) 0)
  (set! (ansi-backend-sgr-transitions b) 0)
  (set! (ansi-backend-cursor-moves b) 0)
  (set! (ansi-backend-image-transmits b) 0)
  (set! (ansi-backend-image-transmit-bytes b) 0)
  (set! (ansi-backend-placements-placed b) 0)
  (set! (ansi-backend-placements-deleted b) 0))

(define (ensure-term-size! b w h)
  "Ensure the backend's cur and prev terms exist at WxH. Resize or
allocate as needed. On resize, also clears the physical terminal so
diff-emitted cells overwrite a known blank state — without this the
old frame's bytes at coordinates the new frame doesn't paint remain
on screen as ghosts.

`prev` may be #f independently of `cur`: process-one's resize branch
nulls it to force a full repaint, so we have to handle the case where
cur exists at the wrong size and prev needs (re)allocation."
  (let ((cur  (ansi-backend-cur-term b))
        (prev (ansi-backend-prev-term b)))
    (cond
     ((not cur)
      (set! (ansi-backend-cur-term b)  (t:make-term #:width w #:height h))
      (set! (ansi-backend-prev-term b) (t:make-term #:width w #:height h)))
     ((or (not (= (t:term-width cur) w))
          (not (= (t:term-height cur) h)))
      (let ((out (ansi-backend-port b)))
        (display "\x1b[2J\x1b[H" out)
        (force-output out))
      (t:term-resize! cur w h)
      (cond
       (prev (t:term-resize! prev w h) (t:term-clear! prev))
       (else (set! (ansi-backend-prev-term b)
                   (t:make-term #:width w #:height h)))))
     ((not prev)
      ;; cur was already at the right size but prev got nulled (e.g.
      ;; by a no-op-sized resize msg) — give it a fresh blank term.
      (set! (ansi-backend-prev-term b)
            (t:make-term #:width w #:height h))))))

(define-method (backend-draw (b <ansi-backend>) cmds)
  "Render frame CMDS on backend B: partition graphics vs grid cmds,
replay grid cmds onto B's current term, diff against the previous
term, and emit the diff (plus any graphics placements) wrapped in
synchronized-output markers.  Updates metrics and swaps cur/prev so
the next frame diffs against this one."
  (let* ((sz   (backend-size b))         ; goes through method dispatch — subclasses override
         (cur-sz (ansi-backend-size b))
         (w    (if sz (size-width sz)  (size-width cur-sz)))
         (h    (if sz (size-height sz) (size-height cur-sz)))
         (out  (ansi-backend-port b)))
    (ensure-term-size! b w h)
    (let ((cur  (ansi-backend-cur-term b))
          (prev (ansi-backend-prev-term b)))
      (call-with-values (lambda () (split-cmds-for-graphics b cmds))
        (lambda (gfx-cmds grid-cmds)
          (t:term-clear! cur)
          (render-cmds-to-term! cur grid-cmds (ansi-backend-theme b))
          (let* ((diff  (t:term-diff->ansi prev cur))
                 ;; Assemble the whole frame in a string port, then emit
                 ;; with one display + force-output. Two reasons it must
                 ;; be one write:
                 ;; - mode 2026 (synchronized output) buffers the
                 ;;   terminal's paint until the END marker arrives. Most
                 ;;   terminals time out at ~150 ms; over a 37 ms RTT, two
                 ;;   separate writes routinely exceed that, the terminal
                 ;;   aborts buffering, and the user sees the diff paint
                 ;;   cell-by-cell ("columns shift in").
                 ;; - even with sync mode off, splitting the diff also
                 ;;   splits the cursor-hide/show envelope, exposing the
                 ;;   per-cell cursor sweep mid-frame.
                 (buf   (open-output-string)))
            ;; No per-frame cursor hide/show. backend-init emits a one-
            ;; shot \e[?25l at session start; we leave the cursor hidden
            ;; for the whole render lifetime. Earlier attempts wrapped
            ;; each frame in hide + … + show, which made every frame end
            ;; with show immediately followed by the next frame's hide.
            ;; The terminal honored both: cursor flashed visible between
            ;; them, at the diff's resting position — which moves frame
            ;; to frame. Visually that's "an underline glyph drawn
            ;; everywhere" as the cursor flickered through positions.
            (display +sync-begin+ buf)
            (display diff buf)
            (when (pair? gfx-cmds) (emit-images! b buf gfx-cmds))
            (display +sync-end+ buf)
            (let ((frame (get-output-string buf)))
              (display frame out)
              (force-output out)
              (set! (ansi-backend-bytes-out b)
                    (+ (ansi-backend-bytes-out b) (string-length frame))))
            (set! (ansi-backend-frames b)
                  (+ (ansi-backend-frames b) 1))
            (call-with-values (lambda () (count-csi-escapes diff))
              (lambda (sgr cur-moves)
                (set! (ansi-backend-sgr-transitions b)
                      (+ (ansi-backend-sgr-transitions b) sgr))
                (set! (ansi-backend-cursor-moves b)
                      (+ (ansi-backend-cursor-moves b) cur-moves)))))))
      (set! (ansi-backend-cur-term  b) prev)
      (set! (ansi-backend-prev-term b) cur)
      (unless (and (= (size-width cur-sz) w) (= (size-height cur-sz) h))
        (set! (ansi-backend-size b) (size w h))))))

(define-method (backend-init (b <ansi-backend>))
  "Prepare the terminal for B: raw mode, alt screen, hidden cursor,
focus reporting, bracketed paste, kitty keyboard disambiguation,
kitty-graphics capability probe, fresh image state, and a cached
terminal size."
  (enter-raw-mode)
  (enter-alternate-screen)
  (hide-cursor)
  (let ((out (ansi-backend-port b)))
    (display "\x1b[?1004h" out)  ; focus reporting on
    (display "\x1b[?2004h" out)  ; bracketed paste on
    (display "\x1b[>5u"    out)  ; kitty kbd: push flags 1+4 (disambiguate + report alternate keys)
    (force-output out))
  (set! (graphics? b) (detect-kitty-graphics! b))
  (hash-clear! (ansi-backend-image-ids b))
  (hash-clear! (ansi-backend-placements b))
  (set! (ansi-backend-next-image-id b) 1)
  (set! (ansi-backend-next-placement-id b) 1)
  ;; Prefer the portable escape-sequence probe (\e[18t → \e[8;r;ct).
  ;; The TIOCGWINSZ ioctl is the fast path on Linux but isn't always
  ;; reliable on macOS Terminal / Guile builds. Fall back to ioctl, then
  ;; to the cached size, then to a safe 80x24 default.
  (let ((sz (or (query-window-size! b) (get-terminal-size) (size 80 24))))
    (set! (ansi-backend-size b) sz)
    (set! (ansi-backend-cur-term b)  #f)
    (set! (ansi-backend-prev-term b) #f)))

(define-method (backend-shutdown (b <ansi-backend>))
  "Restore the terminal after B was running: delete all kitty
placements and image storage (when graphics? was on), pop kitty
keyboard flags, turn off bracketed paste and focus reporting,
restore cursor, leave the alt screen, and exit raw mode."
  (let ((out (ansi-backend-port b)))
    (when (graphics? b)
      ;; a=d,d=A: delete all placements AND free image storage. Without
      ;; this the terminal holds onto sprite bytes forever.
      (display "\x1b_Ga=d,d=A\x1b\\" out))
    (display "\x1b[<u"     out)  ; kitty kbd: pop flags
    (display "\x1b[?2004l" out)  ; bracketed paste off
    (display "\x1b[?1004l" out)  ; focus reporting off
    (force-output out))
  (show-cursor)
  (exit-alternate-screen)
  (exit-raw-mode))

(define-method (backend-size (b <ansi-backend>))
  "Return B's cached <size>. Updated at init via query-window-size!
and on every <resize> msg the engine cascades."
  (ansi-backend-size b))

(define (request-window-size! b)
  "Send the xterm `report window size in cells' query (\\e[18t) to B's
output port. The terminal answers asynchronously with \\e[8;rows;cols t
which the input parser turns into a <resize> msg. Used as the SIGWINCH
side-channel on platforms where TIOCGWINSZ is unreliable."
  (let ((out (ansi-backend-port b)))
    (display "\x1b[18t" out)
    (force-output out)))

(define (query-window-size! b)
  "Synchronously query B's terminal for its window size by emitting
\\e[18t and reading the \\e[8;rows;cols t response. Returns a <size>
or #f if the deadline expires. Used at init before fibers / input
loops are running; consider it a one-shot probe."
  (let ((in   (current-input-port))
        (deadline-ms 250)
        (start (get-internal-real-time))
        (units internal-time-units-per-second))
    (request-window-size! b)
    (let loop ((buf '()) (saw-t? #f))
      (cond
       (saw-t?
        (parse-window-size-response (list->string (reverse buf))))
       ((char-ready? in)
        (let ((ch (read-char in)))
          (loop (cons ch buf) (eqv? ch #\t))))
       (else
        (let ((elapsed-ms (quotient (* (- (get-internal-real-time) start) 1000)
                                     units)))
          (if (>= elapsed-ms deadline-ms)
              (parse-window-size-response (list->string (reverse buf)))
              (begin (usleep 1000) (loop buf #f)))))))))

(define (parse-window-size-response s)
  "Pull rows/cols out of an \\e[8;rows;cols t response embedded in S.
Returns a <size> or #f."
  (let ((i (string-contains s "\x1b[8;")))
    (and i
         (let* ((tail (substring s (+ i 4)))
                (t-idx (string-index tail #\t)))
           (and t-idx
                (let* ((body (substring tail 0 t-idx))
                       (parts (string-split body #\;)))
                  (and (= (length parts) 2)
                       (let ((h (string->number (car parts)))
                             (w (string->number (cadr parts))))
                         (and h w (positive? h) (positive? w)
                              (size w h))))))))))
