(define-module (gcell protocol)
  #:use-module (oop goops)
  #:use-module (ice-9 match)
  #:use-module (gcell key)
  #:re-export (<key> key key? key-sym key-mods key-event)
  #:export (;; Events.
            <size>    size     size?
            size-width size-height

            <mouse>   mouse    mouse?
            mouse-x mouse-y mouse-button mouse-action

            <tick>    tick     tick?
            tick-n

            <resize>  resize   resize?
            resize-width resize-height

            <focus>   focused  focused?
            <blur>    blurred  blurred?
            <focus-in>  focus-in  focus-in?
            <focus-out> focus-out focus-out?
            <resume>  resumed  resumed?

            <paste>   paste    paste?
            paste-text

            <mount>   mount    mount?
            <unmount> unmount  unmount?

            <init>    init     init?

            ;; Composite & timer cmds.
            batch         batch?
            sequence      sequence?
            every         every?
            after         after?
            cancel        cancel?       cancel-id

            ;; Screen cmds.
            set-title     set-title?    set-title-text
            cursor        cursor?       cursor-mode
            alt-screen    alt-screen?   alt-screen-on?
            mouse-mode    mouse-mode?   mouse-mode-kind
            clear-screen  clear-screen?
            println       println?      println-parts

            ;; App cmds.
            suspend       suspend?
            exec          exec?         exec-command exec-on-done
            set-palette   set-palette?  set-palette-name
            cycle-palette cycle-palette?
            clear-log     clear-log?
            focus         focus?        focus-target))

;;; Commentary:
;;;
;;; Wire types between the engine and user code.  Two kinds of value
;;; cross the boundary:
;;;
;;;   * Events  — input flowing from the world into the app's react
;;;               procedure.  widgets; pattern-matched with
;;;               `is-a?` predicates.
;;;
;;;   * Cmds    — declarative requests returned by react, interpreted
;;;               by the engine (set the title, install a ticker, run
;;;               a subprocess, etc.).  Tagged lists or bare symbols.
;;;
;;; Code:


;;;
;;; Events.
;;;

(define-class <size> ()
  (width  #:init-keyword #:width  #:accessor size-width)
  (height #:init-keyword #:height #:accessor size-height))

(define (size? x)
  "Return #t if X is a <size> event."
  (is-a? x <size>))

(define (size w h)
  "Return a fresh <size> event with width W and height H."
  (make <size> #:width w #:height h))


(define-class <mouse> ()
  (x      #:init-keyword #:x      #:accessor mouse-x)
  (y      #:init-keyword #:y      #:accessor mouse-y)
  (button #:init-keyword #:button #:accessor mouse-button)
  (action #:init-keyword #:action #:accessor mouse-action))

(define (mouse? x)
  "Return #t if X is a <mouse> event."
  (is-a? x <mouse>))

(define (mouse x y button action)
  "Return a fresh <mouse> event at (X, Y) for BUTTON and ACTION."
  (make <mouse> #:x x #:y y #:button button #:action action))


(define-class <tick> ()
  (n #:init-keyword #:n #:init-value 0 #:accessor tick-n))

(define (tick? x)
  "Return #t if X is a <tick> event."
  (is-a? x <tick>))

(define* (tick #:optional (n 0))
  "Return a fresh <tick> event with sequence number N (default 0)."
  (make <tick> #:n n))


(define-class <resize> ()
  (width  #:init-keyword #:width  #:accessor resize-width)
  (height #:init-keyword #:height #:accessor resize-height))

(define (resize? x)
  "Return #t if X is a <resize> event."
  (is-a? x <resize>))

(define (resize w h)
  "Return a fresh <resize> event with new dimensions W by H."
  (make <resize> #:width w #:height h))


;; Terminal focus reports (ESC[I / ESC[O) and resume after SIGTSTP.
;; Constructor and predicate names are past-participle to leave the
;; noun `focus` free for the widget-routing cmd `(focus widget)`.

(define-class <focus> ())

(define (focused? x)
  "Return #t if X is a <focus> event (terminal regained focus)."
  (is-a? x <focus>))

(define (focused)
  "Return a fresh <focus> event."
  (make <focus>))


(define-class <blur> ())

(define (blurred? x)
  "Return #t if X is a <blur> event (terminal lost focus)."
  (is-a? x <blur>))

(define (blurred)
  "Return a fresh <blur> event."
  (make <blur>))


;; Widget-level focus events.  Distinct from terminal-level
;; <focus>/<blur>: these are dispatched by the engine when the
;; `focus` cmd changes the focus chain.  Each widget that joins the
;; chain receives `<focus-in>`; each widget that drops out receives
;; `<focus-out>`.  Widgets that care (textinputs, buttons, etc.) can
;; mirror their own focused? slot in response.

(define-class <focus-in>  ())
(define-class <focus-out> ())

(define (focus-in?  x) (is-a? x <focus-in>))
(define (focus-out? x) (is-a? x <focus-out>))

(define (focus-in)  (make <focus-in>))
(define (focus-out) (make <focus-out>))


(define-class <resume> ())

(define (resumed? x)
  "Return #t if X is a <resume> event (app resumed after SIGTSTP)."
  (is-a? x <resume>))

(define (resumed)
  "Return a fresh <resume> event."
  (make <resume>))


(define-class <paste> ()
  (text #:init-keyword #:text #:accessor paste-text))

(define (paste? x)
  "Return #t if X is a <paste> event."
  (is-a? x <paste>))

(define (paste text)
  "Return a fresh <paste> event carrying the raw pasted string TEXT."
  (make <paste> #:text text))


(define-class <mount> ())

(define (mount? x)
  "Return #t if X is a <mount> event."
  (is-a? x <mount>))

(define (mount)
  "Return a fresh <mount> event."
  (make <mount>))


(define-class <unmount> ())

(define (unmount? x)
  "Return #t if X is an <unmount> event."
  (is-a? x <unmount>))

(define (unmount)
  "Return a fresh <unmount> event."
  (make <unmount>))


;; <init> — sent once by the engine before the first user input.
;; React handles it and returns startup cmds (install a ticker,
;; scandir, hit a socket, etc.).  State mutation happens in place;
;; the cmd return is what reaches the engine.

(define-class <init> ())

(define (init? x)
  "Return #t if X is an <init> event."
  (is-a? x <init>))

(define (init)
  "Return a fresh <init> event."
  (make <init>))


;;;
;;; Composite & timer cmds.
;;;

(define (batch . cmds)
  "Return a cmd that runs CMDS concurrently in arbitrary order."
  (cons 'batch cmds))

(define (batch? c)
  "Return #t if C is a batch cmd."
  (and (pair? c) (eq? (car c) 'batch)))


(define (sequence . cmds)
  "Return a cmd that runs CMDS one after another, awaiting each."
  (cons 'sequence cmds))

(define (sequence? c)
  "Return #t if C is a sequence cmd."
  (and (pair? c) (eq? (car c) 'sequence)))


(define (parse-timer-args who args period-keys)
  "Walk ARGS, a tail of `(every ...)` or `(after ...)` arguments,
returning two values: the resolved period in seconds and the
optional :id.  WHO is the caller name (a symbol) used for error
messages.  PERIOD-KEYS is the alist of accepted period keywords and
their converters (each a procedure of one numeric arg returning
seconds).  ARGS must end with a producer thunk; that thunk is the
return value of `every`/`after`'s match arm and is not returned
here."
  (let loop ((args args) (period #f) (id #f))
    (match args
      ((thunk)
       (unless (procedure? thunk)
         (error (format #f "~a: last arg must be a producer thunk" who) thunk))
       (unless period
         (error (format #f "~a: pass one of ~a"
                        who (map car period-keys))))
       (values period id thunk))
      ((k v . rest)
       (cond
        ((eq? k #:id)
         (loop rest period v))
        ((assq-ref period-keys k)
         => (lambda (convert)
              (loop rest (convert v) id)))
        (else
         (error (format #f "~a: unknown keyword" who) k))))
      (_
       (error (format #f "~a: malformed arguments" who) args)))))

(define %every-period-keys
  `((#:hz      . ,(lambda (hz) (/ 1 hz)))
    (#:seconds . ,(lambda (s)  s))
    (#:ms      . ,(lambda (ms) (/ ms 1000)))))

(define (every . args)
  "Return a cmd that calls a producer thunk on a periodic schedule.
ARGS is a list of keyword/value pairs followed by the producer thunk
as the last element.  Period keywords are #:hz, #:seconds, or #:ms
(exactly one required).  The optional #:id keyword tags the
subscription so a later `cancel` can target it."
  (call-with-values
    (lambda () (parse-timer-args 'every args %every-period-keys))
    (lambda (period id thunk) (list 'every period thunk id))))

(define (every? c)
  "Return #t if C is an every cmd."
  (and (pair? c) (eq? (car c) 'every)))


(define %after-period-keys
  `((#:ms      . ,(lambda (ms) (/ ms 1000)))
    (#:seconds . ,(lambda (s)  s))
    (#:hz      . ,(lambda (hz) (/ 1 hz)))))

(define (after . args)
  "Return a cmd that calls a producer thunk once after a delay.
ARGS is a list of keyword/value pairs followed by the producer thunk
as the last element.  Delay keywords are #:ms, #:seconds, or #:hz
(exactly one required).  The optional #:id keyword tags the
subscription so a later `cancel` can target it."
  (call-with-values
    (lambda () (parse-timer-args 'after args %after-period-keys))
    (lambda (delay id thunk) (list 'after delay thunk id))))

(define (after? c)
  "Return #t if C is an after cmd."
  (and (pair? c) (eq? (car c) 'after)))


(define (cancel id)
  "Return a cmd that cancels the subscription tagged ID."
  (list 'cancel id))

(define (cancel? c)
  "Return #t if C is a cancel cmd."
  (and (pair? c) (eq? (car c) 'cancel)))

(define (cancel-id c)
  "Return the subscription id targeted by cancel cmd C."
  (cadr c))


;;;
;;; Screen cmds.
;;;

(define (set-title s)
  "Return a cmd that sets the terminal window title to string S."
  (list 'set-title s))

(define (set-title? c)
  "Return #t if C is a set-title cmd."
  (and (pair? c) (eq? (car c) 'set-title)))

(define (set-title-text c)
  "Return the title string of set-title cmd C."
  (cadr c))


(define (cursor mode)
  "Return a cmd that sets the cursor mode.  MODE is one of: hidden,
hide, visible, show, bar, underline, block."
  (list 'cursor mode))

(define (cursor? c)
  "Return #t if C is a cursor cmd."
  (and (pair? c) (eq? (car c) 'cursor)))

(define (cursor-mode c)
  "Return the cursor mode symbol of cmd C."
  (cadr c))


(define (alt-screen mode)
  "Return a cmd that enters or leaves the alternate screen buffer.
MODE is 'on or 'off."
  (list 'alt-screen mode))

(define (alt-screen? c)
  "Return #t if C is an alt-screen cmd."
  (and (pair? c) (eq? (car c) 'alt-screen)))

(define (alt-screen-on? c)
  "Return #t if alt-screen cmd C requests entering the alt screen."
  (eq? (cadr c) 'on))


(define (mouse-mode mode)
  "Return a cmd that sets the mouse reporting mode.  MODE is one of:
off, click, cell, all."
  (list 'mouse-mode mode))

(define (mouse-mode? c)
  "Return #t if C is a mouse-mode cmd."
  (and (pair? c) (eq? (car c) 'mouse-mode)))

(define (mouse-mode-kind c)
  "Return the mouse mode symbol of cmd C."
  (cadr c))


(define (clear-screen)
  "Return a cmd that forces a full screen redraw."
  'clear-screen)

(define (clear-screen? c)
  "Return #t if C is a clear-screen cmd."
  (eq? c 'clear-screen))


(define (println . parts)
  "Return a cmd that prints PARTS (strings or printable values) to
the real terminal between alt-screen swaps."
  (cons 'println parts))

(define (println? c)
  "Return #t if C is a println cmd."
  (and (pair? c) (eq? (car c) 'println)))

(define (println-parts c)
  "Return the parts list of println cmd C."
  (cdr c))


;;;
;;; App cmds.
;;;

(define (suspend)
  "Return a cmd that suspends the app via SIGTSTP, restoring the
terminal first.  The engine sends a <resume> event when the app
resumes."
  'suspend)

(define (suspend? c)
  "Return #t if C is a suspend cmd."
  (eq? c 'suspend))


(define* (exec command #:key on-done)
  "Return a cmd that runs shell COMMAND, restoring the terminal first
and reinstalling it on return.  If ON-DONE is supplied, it is called
with the exit status and should return a msg to send back into the
engine (or #f)."
  (list 'exec command on-done))

(define (exec? c)
  "Return #t if C is an exec cmd."
  (and (pair? c) (eq? (car c) 'exec)))

(define (exec-command c)
  "Return the shell command string of exec cmd C."
  (cadr c))

(define (exec-on-done c)
  "Return the on-done callback of exec cmd C, or #f if none."
  (caddr c))


(define (set-palette name)
  "Return a cmd that switches the active theme palette to NAME."
  (list 'set-palette name))

(define (set-palette? c)
  "Return #t if C is a set-palette cmd."
  (and (pair? c) (eq? (car c) 'set-palette)))

(define (set-palette-name c)
  "Return the palette name of set-palette cmd C."
  (cadr c))


(define (cycle-palette)
  "Return a cmd that cycles to the next theme palette."
  'cycle-palette)

(define (cycle-palette? c)
  "Return #t if C is a cycle-palette cmd."
  (eq? c 'cycle-palette))


(define (clear-log)
  "Return a cmd that clears the engine log overlay."
  'clear-log)

(define (clear-log? c)
  "Return #t if C is a clear-log cmd."
  (eq? c 'clear-log))


(define (focus w)
  "Return a cmd that routes input focus to widget W."
  (list 'focus w))

(define (focus? c)
  "Return #t if C is a focus cmd (widget routing)."
  (and (pair? c) (eq? (car c) 'focus)))

(define (focus-target c)
  "Return the widget targeted by focus cmd C."
  (cadr c))
