#!/usr/bin/env guile
!#

(add-to-load-path (dirname (dirname (current-filename))))
(add-to-load-path "/opt/homebrew/share/guile/site/3.0")

(use-modules (tuition terminal)
             (tuition style)
             (tuition protocol)
             (tuition app)
             (tuition layout)
             (tuition borders)
             (tuition table)
             (tuition component)
             (tuition components textinput)
             (tuition components progress)
             (tuition components spinner)
             (tuition components viewport)
             (tuition zones)
             (tuition mouse)
             (ice-9 match)
             (ice-9 receive)
             (ice-9 format)
             (srfi srfi-1)
             (oop goops))

;;; Model
(define-class <model> ()
  (tab #:init-value 'components #:accessor tab)
  (input #:init-value #f #:accessor input-field)
  (progress #:init-value 0 #:accessor progress-val)
  (spinner #:init-value #f #:accessor spinner-field)
  (click-count #:init-value 0 #:accessor click-count)
  (mouse-x #:init-value 0 #:accessor mouse-x)
  (mouse-y #:init-value 0 #:accessor mouse-y)
  (mouse-clicks #:init-value 0 #:accessor mouse-clicks)
  (viewport-x #:init-value 0 #:accessor viewport-x)
  (viewport-y #:init-value 0 #:accessor viewport-y))

;;; Messages
(define-class <tick> ())

;;; Init
(define (init m)
  (set! (input-field m) (make-textinput #:placeholder "Type something..." #:width 30))
  (set! (spinner-field m) (make-spinner #:frames spinner-dots))
  ;; Start tick
  (lambda ()
    (usleep 100000) ; 100ms in microseconds
    (make <tick>)))

;;; Update
(define (update m msg)
  (cond
   ;; Tick
   ((is-a? msg <tick>)
    (spinner-tick! (spinner-field m))
    (set! (progress-val m) (modulo (+ (progress-val m) 1) 101))
    (values m
            (lambda ()
              (usleep 100000)
              (make <tick>))))

   ;; Keys - only handle app-level keys
   ((is-a? msg <key-msg>)
    (let ((k (key msg)))
      (cond
       ((or (and (char? k) (char=? k #\q))
            (and (char? k) (char=? k #\Q)))
        (values m (quit-cmd)))
       ((eq? k 'escape)
        (component-blur! (input-field m))
        (values m #f))
       ((and (char? k) (char=? k #\1))
        (set! (tab m) 'components)
        (component-blur! (input-field m))
        (values m #f))
       ((and (char? k) (char=? k #\2))
        (set! (tab m) 'table)
        (component-blur! (input-field m))
        (values m #f))
       ((and (char? k) (char=? k #\3))
        (set! (tab m) 'input)
        (component-focus! (input-field m))
        (values m #f))
       ((and (char? k) (char=? k #\4))
        (set! (tab m) 'styling)
        (component-blur! (input-field m))
        (values m #f))
       ((and (char? k) (char=? k #\5))
        (set! (tab m) 'viewport)
        (component-blur! (input-field m))
        (values m #f))
       ((and (char? k) (char=? k #\space))
        (set! (click-count m) (1+ (click-count m)))
        (values m #f))
       ((and (eq? (tab m) 'viewport)
             (or (eq? k 'up) (eq? k 'down) (eq? k 'left) (eq? k 'right)))
        (cond
         ((eq? k 'up)
          (set! (viewport-y m) (max 0 (- (viewport-y m) 1)))
          (values m #f))
         ((eq? k 'down)
          (set! (viewport-y m) (+ (viewport-y m) 1))
          (values m #f))
         ((eq? k 'left)
          (set! (viewport-x m) (max 0 (- (viewport-x m) 1)))
          (values m #f))
         ((eq? k 'right)
          (set! (viewport-x m) (+ (viewport-x m) 1))
          (values m #f))))
       (else (values m #f)))))

   ;; Mouse
   ((is-a? msg <mouse-msg>)
    (set! (mouse-x m) (x msg))
    (set! (mouse-y m) (y msg))
    (when (eq? (action msg) 'press)
      (set! (mouse-clicks m) (1+ (mouse-clicks m))))
    (when (eq? (action msg) 'release)
      (cond
       ((zone-in-bounds? (zone-get "tab1") msg)
        (set! (tab m) 'components)
        (component-blur! (input-field m)))
       ((zone-in-bounds? (zone-get "tab2") msg)
        (set! (tab m) 'table)
        (component-blur! (input-field m)))
       ((zone-in-bounds? (zone-get "tab3") msg)
        (set! (tab m) 'input)
        (component-focus! (input-field m)))
       ((zone-in-bounds? (zone-get "tab4") msg)
        (set! (tab m) 'styling)
        (component-blur! (input-field m)))
       ((zone-in-bounds? (zone-get "tab5") msg)
        (set! (tab m) 'viewport)
        (component-blur! (input-field m)))))
    ;; Handle scroll in viewport tab
    (when (and (eq? (tab m) 'viewport)
               (or (eq? (action msg) 'scroll-up)
                   (eq? (action msg) 'scroll-down)))
      (if (eq? (action msg) 'scroll-up)
          (set! (viewport-y m) (max 0 (- (viewport-y m) 3)))
          (set! (viewport-y m) (+ (viewport-y m) 3))))
    (values m #f))

   (else (values m #f))))
;;; View
(define (view m)
  (let ((content
         (match (tab m)
           ('components (view-components m))
           ('table (view-table m))
           ('input (view-input m))
           ('styling (view-styling m))
           ('viewport (view-viewport m)))))

    (zone-scan
     (vbox
      (pad (align (fg "guile-tuition showcase" "#ff6b9d") 'center #:width-val 60) #:bottom 1)
      (hbox (zone-mark "tab1"
                       (if (eq? (tab m) 'components)
                           (boxed "Components" #:border border-thick #:fg "#00ff87")
                           (boxed "Components" #:border border-normal #:fg "#888")))
            " "
            (zone-mark "tab2"
                       (if (eq? (tab m) 'table)
                           (boxed "Table" #:border border-thick #:fg "#00ff87")
                           (boxed "Table" #:border border-normal #:fg "#888")))
            " "
            (zone-mark "tab3"
                       (if (eq? (tab m) 'input)
                           (boxed "Input" #:border border-thick #:fg "#00ff87")
                           (boxed "Input" #:border border-normal #:fg "#888")))
            " "
            (zone-mark "tab4"
                       (if (eq? (tab m) 'styling)
                           (boxed "Styling" #:border border-thick #:fg "#00ff87")
                           (boxed "Styling" #:border border-normal #:fg "#888")))
            " "
            (zone-mark "tab5"
                       (if (eq? (tab m) 'viewport)
                           (boxed "Viewport" #:border border-thick #:fg "#00ff87")
                           (boxed "Viewport" #:border border-normal #:fg "#888"))))
      (spacer 1)
      content
      (spacer 1)
      (txt "1/2/3/4/5: switch tabs | esc: unfocus input | space: click | q: quit" #:fg "#888")
      (error-console app)))))

(define (view-components m)
  (vbox
   (txt "Progress Bar:" #:bold? #t)
   (spacer 1)
   (progress-render (make-progress #:current (progress-val m) #:total 100))
   (spacer 2)
   (txt "Spinner:" #:bold? #t)
   (spacer 1)
   (hbox (spinner-render (spinner-field m)) " Loading...")
   (spacer 2)
   (txt "Border Styles:" #:bold? #t)
   (spacer 1)
   (hbox (boxed "Normal" #:border border-normal)
         "  "
         (boxed "Rounded" #:border border-rounded)
         "  "
         (boxed "Thick" #:border border-thick))
   (spacer 2)
   (txt "Click Counter (press space):" #:bold? #t)
   (spacer 1)
   (boxed (string-append "Clicks: " (number->string (click-count m)))
          #:border border-double #:fg "#00ff87")))

(define (view-table m)
  (let ((tbl (make-table #:headers '("Language" "Greeting" "Color")
                        #:border border-rounded)))
    (table-add-row tbl (list "Scheme" "Hello" (fg "Green" "#00ff00")))
    (table-add-row tbl (list "Python" "Hola" (fg "Blue" "#5599ff")))
    (table-add-row tbl (list "Rust" "Bonjour" (fg "Orange" "#ff8800")))
    (vbox
     (txt "Table Component:" #:bold? #t)
     (spacer 1)
     (table-render tbl))))

(define (view-input m)
  (vbox
   (txt "Text Input Component:" #:bold? #t)
   (spacer 1)
   (textinput-view (input-field m))
   (spacer 2)
   (txt (string-append "Value: \"" (textinput-value (input-field m)) "\"") #:fg "#888")
   (spacer 1)
   (txt "Type chars, use arrows, home/end, backspace" #:fg "#888")))

(define (view-styling m)
  (vbox
   (txt "Text Attributes:" #:bold? #t)
   (spacer 1)
   (hbox (bold "Bold")
         "  "
         (italic "Italic")
         "  "
         (underline "Underline")
         "  "
         (strikethrough "Strikethrough")
         "  "
         (fg (bold (italic "Combined")) "#ff00ff"))
   (spacer 2)
   (txt "RGB Colors:" #:bold? #t)
   (spacer 1)
   (hbox (fg "Red" '(255 50 50))
         "  "
         (fg "Orange" "#ff8800")
         "  "
         (fg "Yellow" "#ffff00")
         "  "
         (fg "Green" '(0 255 100))
         "  "
         (fg "Cyan" "#00ffff")
         "  "
         (fg "Blue" '(50 100 255))
         "  "
         (fg "Purple" "#ff00ff"))
   (spacer 2)
   (txt "Padding & Alignment:" #:bold? #t)
   (spacer 1)
   (hbox (pad (boxed "Left" #:border border-rounded #:fg "#87ceeb") #:all 1)
         "  "
         (pad (align (boxed "Center" #:border border-rounded #:fg "#ffa07a") 'center) #:all 1)
         "  "
         (pad (align (boxed "Right" #:border border-rounded #:fg "#98fb98") 'right) #:all 1))
   (spacer 2)
   (txt "Width & Height:" #:bold? #t)
   (spacer 1)
   (hbox (width (height (pad (fg "Fixed 20x5" "#ffd700") #:all 1) 5) 20 #:align-mode 'center)
         "  "
         (width (height (pad (fg "Box 15x3" "#ff69b4") #:left 2 #:right 2) 3 #:valign 'center) 15))
   (spacer 2)
   (txt "Mouse Tracking:" #:bold? #t)
   (spacer 1)
   (pad (vbox
         (txt (format #f "Position: (~a, ~a)" (mouse-x m) (mouse-y m)) #:fg "#87ceeb")
         (txt (format #f "Clicks: ~a" (mouse-clicks m)) #:fg "#ffa500"))
        #:left 2)))

(define (view-viewport m)
  (let* ((large-content
          (apply vbox
                 (map (lambda (i)
                       (apply hbox
                              (map (lambda (j)
                                    (cond
                                     ((and (= i 10) (= j 10)) (fg "@" "#ffff00"))
                                     ((or (= i 0) (= i 29) (= j 0) (= j 49)) (fg "#" "#888"))
                                     ((and (> i 5) (< i 15) (> j 20) (< j 30)) (fg "~" "#00aaff"))
                                     ((and (> i 15) (< i 20) (> j 10) (< j 15)) (fg "^" "#00ff00"))
                                     (else ".")))
                                   (iota 50))))
                      (iota 30)))))
    (vbox
     (txt "Viewport Component:" #:bold? #t)
     (spacer 1)
     (txt "Arrow keys to scroll a 30x50 world" #:fg "#888")
     (spacer 1)
     (boxed (viewport large-content
                     #:width 40
                     #:height 12
                     #:offset-x (viewport-x m)
                     #:offset-y (viewport-y m))
            #:border border-rounded
            #:fg "#87ceeb")
     (spacer 1)
     (txt (format #f "Offset: (~a, ~a)" (viewport-x m) (viewport-y m)) #:fg "#888"))))

;;; Run
(define model (make <model>))
(define app (make-app model (current-module)))
(run-app app)
