(define-module (canary term types)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (rnrs bytevectors)
  #:use-module (canary term modes)
  #:re-export (mode-get mode-set! mode-save! mode-restore! mode-reset!)
  #:export (<face-attrs>
            make-face-attrs
            face-attrs?
            face-fg set-face-fg!
            face-bg set-face-bg!
            face-bold? set-face-bold!
            face-faint? set-face-faint!
            face-italic? set-face-italic!
            face-underline set-face-underline!
            face-ul-color set-face-ul-color!
            face-blink set-face-blink!
            face-inverse? set-face-inverse!
            face-conceal? set-face-conceal!
            face-crossed? set-face-crossed!
            default-face-attrs
            copy-face-attrs
            face-attrs-equal?
            reset-face-attrs!

            <term>
            make-term
            term?
            term-width set-term-width!
            term-height set-term-height!
            term-chars set-term-chars!
            term-faces set-term-faces!
            term-main-chars set-term-main-chars!
            term-main-faces set-term-main-faces!
            term-cursor-x set-term-cursor-x!
            term-cursor-y set-term-cursor-y!
            term-pending-wrap? set-term-pending-wrap!
            term-saved-cursor-x set-term-saved-cursor-x!
            term-saved-cursor-y set-term-saved-cursor-y!
            term-saved-pending-wrap? set-term-saved-pending-wrap!
            term-saved-attrs set-term-saved-attrs!
            term-attrs set-term-attrs!
            term-scroll-top set-term-scroll-top!
            term-scroll-bottom set-term-scroll-bottom!
            term-parser-state set-term-parser-state!
            term-csi-params set-term-csi-params!
            term-csi-format set-term-csi-format!
            term-osc-buf set-term-osc-buf!
            term-modes
            term-cursor-style set-term-cursor-style!
            term-g0 set-term-g0!
            term-g1 set-term-g1!
            term-g2 set-term-g2!
            term-g3 set-term-g3!
            term-active-charset set-term-active-charset!
            term-scrollback set-term-scrollback!
            term-scrollback-size set-term-scrollback-size!
            term-max-scrollback
            term-input-fn set-term-input-fn!
            term-bell-fn set-term-bell-fn!
            term-title-fn set-term-title-fn!
            term-cwd-fn set-term-cwd-fn!
            term-title set-term-title!
            term-cwd set-term-cwd!
            term-last-char set-term-last-char!
            term-in-alt? set-term-in-alt!
            term-last-write-face set-term-last-write-face!

            term-char-at term-face-at
            set-term-char-at! set-term-face-at!
            set-term-cell-at!
            term-clear!
            term-clear-row!
            term-copy-row!
            term-copy!
            term-reset!
            term-resize!

            +wide-cont+ wide-cont?))

(define-record-type <face-attrs>
  (%make-face-attrs fg bg bold? faint? italic? underline ul-color
                    blink inverse? conceal? crossed?)
  face-attrs?
  (fg          face-fg          set-face-fg!)
  (bg          face-bg          set-face-bg!)
  (bold?       face-bold?       set-face-bold!)
  (faint?      face-faint?      set-face-faint!)
  (italic?     face-italic?     set-face-italic!)
  (underline   face-underline   set-face-underline!)
  (ul-color    face-ul-color    set-face-ul-color!)
  (blink       face-blink       set-face-blink!)
  (inverse?    face-inverse?    set-face-inverse!)
  (conceal?    face-conceal?    set-face-conceal!)
  (crossed?    face-crossed?    set-face-crossed!))

(define* (make-face-attrs #:key (fg #f) (bg #f) (bold? #f) (faint? #f)
                          (italic? #f) (underline #f) (ul-color #f)
                          (blink #f) (inverse? #f) (conceal? #f)
                          (crossed? #f))
  "Return a fresh <face-attrs> with the given attribute slots.
Each slot defaults to #f (unset)."
  (%make-face-attrs fg bg bold? faint? italic? underline ul-color
                    blink inverse? conceal? crossed?))

(define (default-face-attrs)
  "Return a fresh <face-attrs> with every slot unset.  Equivalent
to `(make-face-attrs)` but skips the keyword parsing."
  (%make-face-attrs #f #f #f #f #f #f #f #f #f #f #f))

(define (copy-face-attrs f)
  "Return a fresh <face-attrs> whose slots are copied from F."
  (%make-face-attrs (face-fg f) (face-bg f) (face-bold? f)
                    (face-faint? f) (face-italic? f) (face-underline f)
                    (face-ul-color f) (face-blink f) (face-inverse? f)
                    (face-conceal? f) (face-crossed? f)))

(define (face-attrs-equal? a b)
  "Return #t if A and B carry the same attribute slot values.
Eq-identical, both-#f, and slot-wise equal all qualify."
  (cond
   ((eq? a b) #t)
   ((or (not a) (not b)) #f)
   (else
    (and (equal? (face-fg a) (face-fg b))
         (equal? (face-bg a) (face-bg b))
         (eq? (face-bold? a) (face-bold? b))
         (eq? (face-faint? a) (face-faint? b))
         (eq? (face-italic? a) (face-italic? b))
         (equal? (face-underline a) (face-underline b))
         (equal? (face-ul-color a) (face-ul-color b))
         (equal? (face-blink a) (face-blink b))
         (eq? (face-inverse? a) (face-inverse? b))
         (eq? (face-conceal? a) (face-conceal? b))
         (eq? (face-crossed? a) (face-crossed? b))))))

(define (reset-face-attrs! f)
  "Clear every slot of <face-attrs> F to its unset state in place."
  (set-face-fg! f #f)
  (set-face-bg! f #f)
  (set-face-bold! f #f)
  (set-face-faint! f #f)
  (set-face-italic! f #f)
  (set-face-underline! f #f)
  (set-face-ul-color! f #f)
  (set-face-blink! f #f)
  (set-face-inverse! f #f)
  (set-face-conceal! f #f)
  (set-face-crossed! f #f))

(define-record-type <term>
  (%make-term width height chars faces main-chars main-faces
              cx cy pending-wrap?
              saved-cx saved-cy saved-pending-wrap? saved-attrs attrs
              scroll-top scroll-bottom
              parser-state csi-params csi-format osc-buf
              modes cursor-style
              g0 g1 g2 g3 active-charset
              scrollback scrollback-size max-scrollback
              input-fn bell-fn title-fn cwd-fn
              title cwd last-char in-alt?
              last-write-face)
  term?
  (width            term-width            set-term-width!)
  (height           term-height           set-term-height!)
  (chars            term-chars            set-term-chars!)
  (faces            term-faces            set-term-faces!)
  (main-chars       term-main-chars       set-term-main-chars!)
  (main-faces       term-main-faces       set-term-main-faces!)
  (cx               term-cursor-x         set-term-cursor-x!)
  (cy               term-cursor-y         set-term-cursor-y!)
  (pending-wrap?    term-pending-wrap?    set-term-pending-wrap!)
  (saved-cx         term-saved-cursor-x   set-term-saved-cursor-x!)
  (saved-cy         term-saved-cursor-y   set-term-saved-cursor-y!)
  (saved-pending-wrap? term-saved-pending-wrap?
                       set-term-saved-pending-wrap!)
  (saved-attrs      term-saved-attrs      set-term-saved-attrs!)
  (attrs            term-attrs            set-term-attrs!)
  (scroll-top       term-scroll-top       set-term-scroll-top!)
  (scroll-bottom    term-scroll-bottom    set-term-scroll-bottom!)
  (parser-state     term-parser-state     set-term-parser-state!)
  (csi-params       term-csi-params       set-term-csi-params!)
  (csi-format       term-csi-format       set-term-csi-format!)
  (osc-buf          term-osc-buf          set-term-osc-buf!)
  (modes            term-modes)
  (cursor-style     term-cursor-style     set-term-cursor-style!)
  (g0               term-g0               set-term-g0!)
  (g1               term-g1               set-term-g1!)
  (g2               term-g2               set-term-g2!)
  (g3               term-g3               set-term-g3!)
  (active-charset   term-active-charset   set-term-active-charset!)
  (scrollback       term-scrollback       set-term-scrollback!)
  (scrollback-size  term-scrollback-size  set-term-scrollback-size!)
  (max-scrollback   term-max-scrollback)
  (input-fn         term-input-fn         set-term-input-fn!)
  (bell-fn          term-bell-fn          set-term-bell-fn!)
  (title-fn         term-title-fn         set-term-title-fn!)
  (cwd-fn           term-cwd-fn           set-term-cwd-fn!)
  (title            term-title            set-term-title!)
  (cwd              term-cwd              set-term-cwd!)
  (last-char        term-last-char        set-term-last-char!)
  (in-alt?          term-in-alt?          set-term-in-alt!)
  (last-write-face  term-last-write-face  set-term-last-write-face!))

(define %space (char->integer #\space))

;; Sentinel code point stored in the cell immediately to the right of a
;; wide character. The terminal's natural rendering of the wide char
;; already covered that visual column; the renderer skips sentinel cells
;; so we don't move the cursor or write garbage on top of the wide char.
(define +wide-cont+ 0)

(define (wide-cont? cp)
  "Return #t if code point CP is the wide-char sentinel."
  (= cp +wide-cont+))

(define (alloc-chars n)
  "Return a fresh u32vector of N cells, each initialised to space."
  (make-u32vector n %space))

(define (alloc-faces n)
  "Return a fresh vector of N face slots, each initialised to #f."
  (make-vector n #f))

(define* (make-term #:key (width 80) (height 24)
                    (input-fn #f) (bell-fn #f)
                    (title-fn #f) (cwd-fn #f)
                    (max-scrollback 10000))
  "Return a fresh <term> of WIDTH × HEIGHT cells.  INPUT-FN /
BELL-FN / TITLE-FN / CWD-FN are optional callbacks invoked by the
parser when the emulated program writes input / rings the bell /
sets the title / reports the cwd.  MAX-SCROLLBACK caps the
scrollback ring; 0 disables it."
  (let ((n (* width height)))
    (%make-term width height
                (alloc-chars n) (alloc-faces n)
                #f #f
                0 0 #f
                0 0 #f (default-face-attrs) (default-face-attrs)
                0 (- height 1)
                #f '() #f ""
                (make-mode-state)
                'block
                'us-ascii 'us-ascii 'us-ascii 'us-ascii 'g0
                (if (positive? max-scrollback)
                    (make-vector 64 #f)
                    #f)
                0 max-scrollback
                input-fn bell-fn title-fn cwd-fn
                "" "" #\space #f
                #f)))

(define (term-index t x y)
  "Return the flat cell-array index for cell (X, Y) in T."
  (+ (* y (term-width t)) x))

(define (term-char-at t x y)
  "Return the character at cell (X, Y) of T."
  (integer->char (u32vector-ref (term-chars t) (term-index t x y))))

(define (term-face-at t x y)
  "Return the face at cell (X, Y) of T (or #f for default)."
  (vector-ref (term-faces t) (term-index t x y)))

(define (set-term-char-at! t x y ch)
  "Write character CH into cell (X, Y) of T, leaving the face
unchanged."
  (u32vector-set! (term-chars t) (term-index t x y) (char->integer ch)))

(define (set-term-face-at! t x y face)
  "Write FACE into cell (X, Y) of T, leaving the character
unchanged."
  (vector-set! (term-faces t) (term-index t x y) face))

(define (set-term-cell-at! t x y ch face)
  "Write character CH with face FACE into cell (X, Y) of T."
  (let ((i (term-index t x y)))
    (u32vector-set! (term-chars t) i (char->integer ch))
    (vector-set! (term-faces t) i face)))

(define* (term-clear! t #:optional (face #f))
  "Fill every cell of T with a space.  Optional FACE applies to the
filled cells (defaults to #f / no face)."
  (let ((chars (term-chars t))
        (faces (term-faces t))
        (n (* (term-width t) (term-height t))))
    (do ((i 0 (+ i 1)))
        ((= i n))
      (u32vector-set! chars i %space)
      (vector-set!    faces i face))))

(define* (term-clear-row! t y #:optional (face #f))
  "Fill row Y of T with spaces, optionally in FACE."
  (let* ((w (term-width t))
         (chars (term-chars t))
         (faces (term-faces t))
         (start (* y w))
         (end   (+ start w)))
    (do ((i start (+ i 1)))
        ((= i end))
      (u32vector-set! chars i %space)
      (vector-set!    faces i face))))

(define (term-copy-row! t src-y dst-y)
  "Copy row SRC-Y of T over row DST-Y in place."
  (let* ((w (term-width t))
         (chars (term-chars t))
         (faces (term-faces t))
         (src (* src-y w))
         (dst (* dst-y w)))
    (do ((i 0 (+ i 1)))
        ((= i w))
      (u32vector-set! chars (+ dst i) (u32vector-ref chars (+ src i)))
      (vector-set!    faces (+ dst i) (vector-ref    faces (+ src i))))))

(define (term-copy! dst src)
  "Copy the visible grid of SRC into DST. Both must have the same dimensions."
  (let* ((w (term-width src))
         (h (term-height src))
         (n (* w h))
         (sc (term-chars src))
         (sf (term-faces src))
         (dc (term-chars dst))
         (df (term-faces dst)))
    (do ((i 0 (+ i 1)))
        ((= i n))
      (u32vector-set! dc i (u32vector-ref sc i))
      (vector-set!    df i (vector-ref    sf i)))))

(define (term-reset! t)
  "Reset T to its initial state: parser cleared, cursor home, scroll
region whole screen, modes back to defaults, charset slots back to
us-ascii, attrs cleared, grid cleared, alt-screen exited."
  (set-term-parser-state! t #f)
  (set-term-csi-params! t '())
  (set-term-csi-format! t #f)
  (set-term-osc-buf! t "")
  (set-term-cursor-x! t 0)
  (set-term-cursor-y! t 0)
  (set-term-pending-wrap! t #f)
  (set-term-scroll-top! t 0)
  (set-term-scroll-bottom! t (- (term-height t) 1))
  (mode-reset! (term-modes t))
  (set-term-cursor-style! t 'block)
  (set-term-active-charset! t 'g0)
  (set-term-g0! t 'us-ascii)
  (set-term-g1! t 'us-ascii)
  (set-term-g2! t 'us-ascii)
  (set-term-g3! t 'us-ascii)
  (reset-face-attrs! (term-attrs t))
  (term-clear! t)
  (when (term-in-alt? t)
    (set-term-chars! t (term-main-chars t))
    (set-term-faces! t (term-main-faces t))
    (set-term-main-chars! t #f)
    (set-term-main-faces! t #f)
    (set-term-in-alt! t #f)))

(define (copy-region! src-chars src-faces src-w
                      dst-chars dst-faces dst-w
                      copy-w copy-h)
  "Copy a COPY-W × COPY-H region from the top-left of one grid
buffer pair into another.  SRC-W and DST-W are the row strides of
the source and destination grids respectively."
  (do ((y 0 (+ y 1)))
      ((= y copy-h))
    (do ((x 0 (+ x 1)))
        ((= x copy-w))
      (let ((si (+ (* y src-w) x))
            (di (+ (* y dst-w) x)))
        (u32vector-set! dst-chars di (u32vector-ref src-chars si))
        (vector-set!    dst-faces di (vector-ref    src-faces si))))))

(define (term-resize! t cols rows)
  "Resize T to COLS × ROWS, preserving the top-left COPY-W × COPY-H
slice of the visible grid (and the alt-screen backup, if any).
Resets the scroll region to the full new height and clamps the
cursor into the new bounds.  No-op if dimensions are unchanged or
non-positive."
  (when (and (positive? cols) (positive? rows)
             (or (not (= cols (term-width t)))
                 (not (= rows (term-height t)))))
    (let* ((old-w (term-width t))
           (old-h (term-height t))
           (n     (* cols rows))
           (new-chars (alloc-chars n))
           (new-faces (alloc-faces n))
           (copy-w (min old-w cols))
           (copy-h (min old-h rows)))
      (copy-region! (term-chars t) (term-faces t) old-w
                    new-chars new-faces cols
                    copy-w copy-h)
      (set-term-chars! t new-chars)
      (set-term-faces! t new-faces)
      (set-term-width! t cols)
      (set-term-height! t rows)
      (set-term-scroll-top! t 0)
      (set-term-scroll-bottom! t (- rows 1))
      (set-term-cursor-x! t (min (term-cursor-x t) (- cols 1)))
      (set-term-cursor-y! t (min (term-cursor-y t) (- rows 1)))
      (set-term-pending-wrap! t #f)
      (when (term-in-alt? t)
        (let ((old-main-chars (term-main-chars t))
              (old-main-faces (term-main-faces t)))
          (when (and old-main-chars old-main-faces)
            (let ((new-main-chars (alloc-chars n))
                  (new-main-faces (alloc-faces n)))
              (copy-region! old-main-chars old-main-faces old-w
                            new-main-chars new-main-faces cols
                            copy-w copy-h)
              (set-term-main-chars! t new-main-chars)
              (set-term-main-faces! t new-main-faces))))))))
