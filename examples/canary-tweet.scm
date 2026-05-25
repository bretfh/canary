#!/usr/bin/env guile
!#
(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (oop goops)
             (ice-9 match)
             (ice-9 format)
             (ice-9 receive)
             (canary)
             (canary components spinner)
             (canary components textinput))

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

(define-class <note> ()
  (age   #:init-value 0          #:accessor note-age)
  (glyph #:init-keyword #:glyph  #:accessor note-glyph))

(define %note-lifetime 30)

(define (advance-notes! notes)
  (filter (lambda (n)
            (set! (note-age n) (+ (note-age n) 1))
            (< (note-age n) %note-lifetime))
          notes))

(define (note-pos n beak-x beak-y)
  (values
   (+ beak-x (inexact->exact (round (* 4 (sin (* (note-age n) 0.45))))))
   (- beak-y (note-age n))))

(define-class <tweet> ()
  (frame #:init-value 0   #:accessor tweet-frame)
  (notes #:init-value '() #:accessor tweet-notes)
  (input #:init-form (make-textinput #:prompt "♪ "
                                     #:placeholder "type to sing"
                                     #:width 40
                                     #:focused? #t)
         #:accessor tweet-input)
  (spin  #:init-form (make-spinner)
         #:accessor tweet-spin))

(define app-theme
  (theme (palette dark
           (accent "#ffd05e")
           (muted  "#888888")
           (hint   "#5a6378")
           (note   "#ff6b9d"))))

(define-method (init (m <tweet>))
  (every #:hz 12 (lambda () (tick))))

(define (beak-pos sz)
  (let* ((cols (size-width  sz))
         (rows (size-height sz))
         (left (max 0 (quotient (- cols %sprite-cells-w) 2)))
         (top  (max 0 (- rows %sprite-h 6))))
    (values (+ left (* 2 %beak-col))
            (+ top  %beak-row))))

(define (spawn-note! m ch)
  (when (char? ch)
    (set! (tweet-notes m)
          (cons (make <note> #:glyph (string ch))
                (tweet-notes m)))))

(define-method (update (m <tweet>) (msg <tick>) sz)
  (set! (tweet-frame m) (+ (tweet-frame m) 1))
  (set! (tweet-notes m) (advance-notes! (tweet-notes m)))
  (update (tweet-spin m) msg sz)
  (values m #f))

(define-method (update (m <tweet>) (msg <key>) sz)
  (update (tweet-input m) msg sz)
  (let ((ch (key-sym msg)))
    (cond
     ((eq? ch 'enter)
      (set! (textinput-value (tweet-input m)) "")
      (set! (textinput-cursor (tweet-input m)) 0))
     ((char? ch) (spawn-note! m ch))))
  (values m #f))

(define-method (update (m <tweet>) msg sz)
  (values m #f))

(define (status-bar m cols)
  (hbox (view (tweet-spin m) #f)
        (txt "  tweeting..." #:fg 'accent #:bold)
        (spacer #:w (max 0 (- cols 26)))
        (txt (format #f "frame ~4d" (tweet-frame m)) #:fg 'muted)))

(define-method (view (m <tweet>) sz)
  (let* ((cols   (size-width sz))
         (rows   (size-height sz))
         (sprite (sprite-node-for (tweet-frame m)))
         (top    (max 0 (- rows %sprite-h 6)))
         (body
          (vbox
           (status-bar m cols)
           (spacer 1)
           (spacer top)
           (align sprite 'center #:width cols)
           (spacer 1)
           (align (view (tweet-input m) sz) 'center #:width cols)
           (spacer 1)
           (align (txt "esc: quit" #:fg 'hint #:italic) 'center #:width cols))))
    (receive (bx by) (beak-pos sz)
      (apply overlay body
             (map (lambda (n)
                    (receive (nx ny) (note-pos n bx by)
                      (pin nx ny (txt (note-glyph n) #:fg 'note #:bold))))
                  (tweet-notes m))))))

(define (main)
  (run-app (make <tweet>)
           #:title  "canary tweet"
           #:theme  app-theme
           #:keymap (keymap (bind 'escape 'quit))))

(main)
