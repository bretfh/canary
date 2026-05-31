#!/usr/bin/env guile
!#
(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (oop goops)
             (ice-9 match)
             (ice-9 format)
             (ice-9 receive)
             (gcell)
             (gcell components spinner)
             (gcell components textinput))

(define %palette
  '((#\. . #f)
    (#\Y . "#ffd05e") (#\D . "#a06b14") (#\K . "#0a0d18")
    (#\O . "#ff8c42") (#\B . "#8b5a2b") (#\C . "#403a39")
    (#\n . "#8e6d44") (#\m . "#735950")))

(define %cell-cache
  (let ((h (make-hash-table)))
    (for-each (lambda (p)
                (let ((c (cdr p)))
                  (hashv-set! h (car p) (txt " " #:bg c))))
              %palette)
    h))

(define (cell-for ch) (or (hashv-ref %cell-cache ch) (txt " ")))

(define (row->hbox row)
  (apply hbox
         (apply append
                (map (lambda (ch) (let ((c (cell-for ch))) (list c c)))
                     (string->list row)))))

(define (sprite->node sprite) (apply vbox (map row->hbox sprite)))

(define %sprite-one
  '(".............CCCCCC............."
    "...............CC..............."
    ".......CCCCCCCCCCCCCCCCCC......."
    "......C..................C......"
    ".....C....................C....."
    "....C......................C...."
    "....C.........YYYY.........C...."
    "....C........YYYKYY........C...."
    "....C.........YYYYOO.......C...."
    "....C.......YYYYYY.........C...."
    "....C......YYYYYYYY........C...."
    "....C......YYYYYYY.........C...."
    "....C.......YYYY...........C...."
    "....C......YY.B.B..........C...."
    "....C......Ynnnnnnnn.......C...."
    "....C..........n...........C...."
    "....C..........n...........C...."
    "....C..........n...........C...."
    "....C..........n...........C...."
    "....CCCCCCCCCCCCCCCCCCCCCCCC...."))

(define %sprite-two
  '(".............CCCCCC............."
    "...............CC..............."
    ".......CCCCCCCCCCCCCCCCCC......."
    "......C..................C......"
    ".....C....................C....."
    "....C......................C...."
    "....C.........YYYY.........C...."
    "....C........YYYYYY........C...."
    "....C.........YYYYOO.......C...."
    "....C.......YYYYYY.........C...."
    "....C......YYYYYYYY........C...."
    "....C......YYYYYYY.........C...."
    "....C.......YYYY...........C...."
    "....C......YY.B.B..........C...."
    "....C......Ynnnnnnnn.......C...."
    "....C..........n...........C...."
    "....C..........n...........C...."
    "....C..........n...........C...."
    "....C..........n...........C...."
    "....CCCCCCCCCCCCCCCCCCCCCCCC...."))

(define %sprite-three
  '(".............CCCCCC............."
    "...............CC..............."
    ".......CCCCCCCCCCCCCCCCCC......."
    "......C..................C......"
    ".....C....................C....."
    "....C......................C...."
    "....C.........YYYY.........C...."
    "....C........YYYKYY........C...."
    "....C.........YYYYOO.......C...."
    "....C.......YYYYYY.........C...."
    "....C......YYYYYYYY........C...."
    "....C......YYYYYYY.........C...."
    "....C.......YYYY...........C...."
    "....C......YY.B.B..........C...."
    "....C......Ynnnnnnnn.......C...."
    "....C..........n...........C...."
    "....C..........n...........C...."
    "....C..........n...........C...."
    "....C..........n...........C...."
    "....CCCCCCCCCCCCCCCCCCCCCCCC...."))

(define %sprite-nodes
  (vector (static (sprite->node %sprite-one))
          (static (sprite->node %sprite-two))
          (static (sprite->node %sprite-one))
          (static (sprite->node %sprite-three))))

(define %sprite-chars-w 32)
(define %sprite-cells-w (* 2 %sprite-chars-w))
(define %sprite-h 20)
(define %beak-col 19)
(define %beak-row 8)

(define (sprite-node-for frame)
  (vector-ref %sprite-nodes (modulo (quotient frame 3) 4)))

(define-class <note> (<focusable>)
  (age   #:init-value 0          #:getter note-age)
  (glyph #:init-keyword #:glyph  #:getter note-glyph))

(define %note-lifetime 30)

(define (advance-notes notes)
  "Return a fresh list of notes one tick older, with notes past their
lifetime filtered out."
  (filter-map (lambda (n)
                (let ((aged (update-slots n #:age (+ (note-age n) 1))))
                  (and (< (note-age aged) %note-lifetime) aged)))
              notes))

(define (note-pos n beak-x beak-y)
  (values
   (+ beak-x (inexact->exact (round (* 4 (sin (* (note-age n) 0.45))))))
   (- beak-y (note-age n))))

(define-class <tweet> (<focusable>)
  (frame #:init-value 0   #:getter tweet-frame)
  (notes #:init-value '() #:getter tweet-notes)
  (cols  #:init-value 80  #:getter tweet-cols)
  (rows  #:init-value 24  #:getter tweet-rows)
  (input #:init-form (textinput #:prompt "♪ "
                                #:placeholder "type to sing"
                                #:width 40
                                #:focused? #t)
         #:getter tweet-input)
  (spin  #:init-form (spinner)
         #:getter tweet-spin))

(define app-theme
  (theme (palette dark
           (accent "#ffd05e")
           (muted  "#888888")
           (hint   "#5a6378")
           (note   "#ff6b9d"))))

;; Startup: tick the sprite at 12hz and put the textinput in the focus
;; chain so the user's keys go there. The spinner installs its own
;; ticker via its <init> method when the cascade reaches it.
(define-method (update (m <tweet>) (msg <init>))
  (cons m (batch (every #:hz 12 (lambda () (tick)))
                 (focus (tweet-input m)))))

(define (beak-pos cols rows)
  (let* ((left (max 0 (quotient (- cols %sprite-cells-w) 2)))
         (top  (max 0 (- rows %sprite-h 6))))
    (values (+ left (* 2 %beak-col))
            (+ top  %beak-row))))

(define (spawn-note m ch)
  "Return M with a new <note> for character CH prepended to its
notes list.  Non-char CH leaves M unchanged."
  (cond
   ((char? ch)
    (update-slots m
      #:notes (cons (make <note> #:glyph (string ch))
                    (tweet-notes m))))
   (else m)))

(define-method (update (m <tweet>) (msg <tick>))
  (cons (update-slots m
          #:frame (+ (tweet-frame m) 1)
          #:notes (advance-notes (tweet-notes m)))
        #f))

(define-method (update (m <tweet>) (msg <resize>))
  (cons (update-slots m
          #:cols (resize-width msg)
          #:rows (resize-height msg))
        #f))

(define-method (update (m <tweet>) (msg <key>))
  ;; The textinput is embedded in our view tree and focused at <init>,
  ;; so the engine routes keys to it through the focus chain.  We get
  ;; the key too (the root sits on the chain).  Spawn a floating note
  ;; on a printable char; clear the input's buffer on enter.
  (let ((ch (key-sym msg)))
    (cons
     (cond
      ((eq? ch 'enter)
       (update-slots m
         #:input (update-slots (tweet-input m) #:value "" #:cursor 0)))
      ((char? ch) (spawn-note m ch))
      (else m))
     #f)))

(define (status-bar m cols)
  (hbox (tweet-spin m)            ; cascade renders + reaches it for <init>
        (txt "  tweeting..." #:fg 'accent #:bold)
        (spacer #:w (max 0 (- cols 26)))
        (txt (format #f "frame ~4d" (tweet-frame m)) #:fg 'muted)))

(define-method (view (m <tweet>))
  (let* ((cols   (tweet-cols m))
         (rows   (tweet-rows m))
         (sprite (sprite-node-for (tweet-frame m)))
         (top    (max 0 (- rows %sprite-h 6)))
         (body
          (vbox
           (status-bar m cols)
           (spacer 1)
           (spacer top)
           (align sprite #:h 'center #:width cols)
           (spacer 1)
           (align (tweet-input m) #:h 'center #:width cols)
           (spacer 1)
           (align (txt "esc: quit" #:fg 'hint #:italic) #:h 'center #:width cols))))
    (receive (bx by) (beak-pos cols rows)
      (apply overlay body
             (map (lambda (n)
                    (receive (nx ny) (note-pos n bx by)
                      (pin nx ny (txt (note-glyph n) #:fg 'note #:bold))))
                  (tweet-notes m))))))

(define (main)
  (run-app (make <tweet>)
           #:title  "gcell tweet"
           #:theme  app-theme
           #:keymap (keymap (bind 'escape 'quit))))

(main)
