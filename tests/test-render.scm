(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (srfi srfi-1)
             (gcell view)
             (gcell layout)
             (gcell borders)
             (gcell draw)
             (gcell render))

(test-begin "render")

(let ((cmds (render (txt "hi") 80 24)))
  (test-equal "single text yields one text-cmd" 1 (length cmds))
  (test-assert "is a text-cmd" (text-cmd? (car cmds)))
  (test-equal "text-cmd has correct string" "hi" (text-str (car cmds)))
  (test-equal "text-cmd at origin" 0 (text-col (car cmds)))
  (test-equal "text-cmd row 0" 0 (text-row (car cmds))))

(let ((cmds (render (vbox (txt "a") (txt "b")) 80 24)))
  (test-equal "vbox yields 2 cmds" 2 (length cmds))
  (test-equal "first row 0" 0 (text-row (car cmds)))
  (test-equal "second row 1" 1 (text-row (cadr cmds))))

(let ((cmds (render (hbox (txt "ab") (txt "cd")) 80 24)))
  (test-equal "hbox yields 2 cmds" 2 (length cmds))
  (test-equal "first col 0" 0 (text-col (car cmds)))
  (test-equal "second col 2" 2 (text-col (cadr cmds))))

(let ((cmds (render (boxed (txt "x")) 80 24)))
  (test-assert "boxed yields multiple cmds" (> (length cmds) 1))
  (test-assert "all are text-cmds" (every text-cmd? cmds)))

;; ── flex distribution ────────────────────────────────────────────────

;; Two flex items, equal grow → 50/50 of leftover.
;; Box height 10, intrinsics 1+1=2, leftover 8, each gets +4 → rows 0,5.
(let ((cmds (render (vbox (flex (txt "a")) (flex (txt "b"))) 10 10)))
  (test-equal "equal grow splits leftover evenly: first at row 0"
              0 (text-row (car cmds)))
  (test-equal "equal grow splits leftover evenly: second at row 5"
              5 (text-row (cadr cmds))))

;; grow=2 vs grow=1 → 2/3 vs 1/3 of leftover.
;; Box height 11, intrinsics 1+1=2, leftover 9, first +6, second +3.
;; first rendered at row 0 with height 7; second at row 7 with height 4.
(let ((cmds (render (vbox (flex (txt "a") #:grow 2)
                          (flex (txt "b") #:grow 1))
                    10 11)))
  (test-equal "2:1 grow: first at row 0" 0 (text-row (car cmds)))
  (test-equal "2:1 grow: second at row 7" 7 (text-row (cadr cmds))))

;; Mixed flex + non-flex: non-flex keeps intrinsic, flex absorbs leftover.
;; Box height 10, txt + flex(txt) + txt = 1+1+1=3, leftover 7 to flex only.
;; rows 0, 1, 9.
(let ((cmds (render (vbox (txt "a") (flex (txt "b")) (txt "c")) 10 10)))
  (test-equal "non-flex keeps intrinsic: a at row 0" 0 (text-row (car cmds)))
  (test-equal "non-flex keeps intrinsic: b absorbs to row 1" 1
              (text-row (cadr cmds)))
  (test-equal "non-flex keeps intrinsic: c at row 9" 9
              (text-row (caddr cmds))))

;; hbox flex: 2:1 grow on width.
;; Box width 11, intrinsics 1+1=2, leftover 9, first +6, second +3.
;; first at col 0 width 7, second at col 7 width 4.
(let ((cmds (render (hbox (flex (txt "a") #:grow 2)
                          (flex (txt "b") #:grow 1))
                    11 1)))
  (test-equal "hbox 2:1 grow: first at col 0" 0 (text-col (car cmds)))
  (test-equal "hbox 2:1 grow: second at col 7" 7 (text-col (cadr cmds))))

;; No flex items → leftover stays blank, items keep intrinsic.
(let ((cmds (render (vbox (txt "a") (txt "b")) 80 10)))
  (test-equal "no flex: first at row 0" 0 (text-row (car cmds)))
  (test-equal "no flex: second at row 1" 1 (text-row (cadr cmds)))
  (test-equal "no flex: only two cmds" 2 (length cmds)))

;; Shrink: total > available, items with shrink share the deficit.
;; vbox of (height txt 6) + (flex (height txt 6) #:grow 0 #:shrink 1)
;; in height 8: total=12, deficit=4, only second shrinks → 6, 2 = 8. ok.
(let ((cmds (render (vbox (height (txt "a") 6)
                          (flex (height (txt "b") 6)
                                #:grow 0 #:shrink 1))
                    10 8)))
  (test-equal "shrink: first keeps height (row 0)" 0 (text-row (car cmds)))
  (test-equal "shrink: second pushed to row 6" 6 (text-row (cadr cmds))))

;; ── align 2D positioning ─────────────────────────────────────────────

;; Centered both axes within 11x11: 1x1 content, slack 10/10, offset 5/5.
(let ((cmds (render (align (txt "x") #:h 'center #:v 'middle) 11 11)))
  (test-equal "align center/middle: col 5" 5 (text-col (car cmds)))
  (test-equal "align center/middle: row 5" 5 (text-row (car cmds))))

;; Right + bottom: 1x1 in 10x10, offsets (9, 9).
(let ((cmds (render (align (txt "x") #:h 'right #:v 'bottom) 10 10)))
  (test-equal "align right/bottom: col 9" 9 (text-col (car cmds)))
  (test-equal "align right/bottom: row 9" 9 (text-row (car cmds))))

;; Default: left/top (no movement).
(let ((cmds (render (align (txt "x")) 10 10)))
  (test-equal "align default: col 0" 0 (text-col (car cmds)))
  (test-equal "align default: row 0" 0 (text-row (car cmds))))

;; Overflow on vertical with 'bottom: content (5 rows) in rect h=3.
;; slack-h = -2 → sub-rect row = -2; first three lines render at rows
;; -2, -1, 0 (clipped) … 0, 1, 2 (visible). The text-cmd whose row
;; falls inside the rect is the last one.
(let* ((items (list (txt "a") (txt "b") (txt "c") (txt "d") (txt "e")))
       (cmds  (render (align (apply vbox items) #:v 'bottom) 10 3))
       (visible (filter (lambda (c) (and (>= (text-row c) 0)
                                          (<  (text-row c) 3)))
                        cmds)))
  (test-equal "align bottom-overflow: 3 rows visible" 3 (length visible))
  (test-equal "align bottom-overflow: last visible is 'e'" "e"
              (text-str (caddr visible))))

(test-end "render")
