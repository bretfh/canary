(define-module (canary protocol)
  #:use-module (oop goops)
  #:use-module (canary key)
  #:re-export (<key> key key? key-sym key-mods)
  #:export (<size> size size? size-width size-height

            <mouse> mouse mouse?
            mouse-x mouse-y mouse-button mouse-action

            <tick> tick tick? tick-n

            <resize> resize resize? resize-width resize-height

            <focus>  focus  focus?
            <blur>   blur   blur?
            <resume> resumed resume?

            <init>   init    init?

            batch sequence batch? sequence?
            every every?
            after after?

            set-title    set-title?    set-title-text
            cursor       cursor?       cursor-mode
            alt-screen   alt-screen?   alt-screen-on?
            mouse-mode   mouse-mode?   mouse-mode-kind
            clear-screen clear-screen?
            println      println?      println-parts
            suspend      suspend?
            exec         exec?         exec-command exec-on-done
            set-palette  set-palette?  set-palette-name
            cycle-palette cycle-palette?
            clear-log    clear-log?
            focus        focus?        focus-target
            cancel       cancel?       cancel-id))

(define-class <size> ()
  (width  #:init-keyword #:width  #:accessor size-width)
  (height #:init-keyword #:height #:accessor size-height))
(define (size? x) (is-a? x <size>))
(define (size w h) (make <size> #:width w #:height h))

(define-class <mouse> ()
  (x      #:init-keyword #:x      #:accessor mouse-x)
  (y      #:init-keyword #:y      #:accessor mouse-y)
  (button #:init-keyword #:button #:accessor mouse-button)
  (action #:init-keyword #:action #:accessor mouse-action))
(define (mouse? x) (is-a? x <mouse>))
(define (mouse x y button action)
  (make <mouse> #:x x #:y y #:button button #:action action))

(define-class <tick> ()
  (n #:init-keyword #:n #:init-value 0 #:accessor tick-n))
(define (tick? x) (is-a? x <tick>))
(define* (tick #:optional (n 0)) (make <tick> #:n n))

(define-class <resize> ()
  (width  #:init-keyword #:width  #:accessor resize-width)
  (height #:init-keyword #:height #:accessor resize-height))
(define (resize? x) (is-a? x <resize>))
(define (resize w h) (make <resize> #:width w #:height h))

(define-class <focus>  ())
(define (focus? x) (is-a? x <focus>))
(define (focus) (make <focus>))

(define-class <blur>   ())
(define (blur? x) (is-a? x <blur>))
(define (blur) (make <blur>))

(define-class <resume> ())
(define (resume? x) (is-a? x <resume>))
(define (resumed) (make <resume>))

;; <init> — sent once by the engine before the first user input msg.
;; Authors handle it in react and return startup cmds (install a
;; ticker, scandir, hit a socket, etc.). State mutation happens in
;; place; the cmd return is what reaches the engine.
(define-class <init> ())
(define (init? x) (is-a? x <init>))
(define (init) (make <init>))

(define (batch . cmds) (cons 'batch cmds))
(define (sequence . cmds) (cons 'sequence cmds))
(define (batch? c)    (and (pair? c) (eq? (car c) 'batch)))
(define (sequence? c) (and (pair? c) (eq? (car c) 'sequence)))

(define (every . args)
  (let loop ((args args) (period #f) (id #f))
    (cond
     ((null? args)       (error "every: pass producer thunk last"))
     ((null? (cdr args))
      (unless period    (error "every: pass #:hz, #:seconds, or #:ms"))
      (list 'every period (car args) id))
     (else
      (let ((k (car args)) (v (cadr args)))
        (case k
          ((#:hz)      (loop (cddr args) (/ 1 v) id))
          ((#:seconds) (loop (cddr args) v id))
          ((#:ms)      (loop (cddr args) (/ v 1000) id))
          ((#:id)      (loop (cddr args) period v))
          (else        (error "every: unknown keyword" k))))))))
(define (every? c) (and (pair? c) (eq? (car c) 'every)))

(define (after . args)
  (let loop ((args args) (delay #f) (id #f))
    (cond
     ((null? args)      (error "after: pass producer thunk last"))
     ((null? (cdr args))
      (unless delay    (error "after: pass #:ms, #:seconds, or #:hz"))
      (list 'after delay (car args) id))
     (else
      (let ((k (car args)) (v (cadr args)))
        (case k
          ((#:ms)      (loop (cddr args) (/ v 1000) id))
          ((#:seconds) (loop (cddr args) v id))
          ((#:hz)      (loop (cddr args) (/ 1 v) id))
          ((#:id)      (loop (cddr args) delay v))
          (else        (error "after: unknown keyword" k))))))))
(define (after? c) (and (pair? c) (eq? (car c) 'after)))

(define (set-title s)        (list 'set-title s))
(define (set-title? c)       (and (pair? c) (eq? (car c) 'set-title)))
(define (set-title-text c)   (cadr c))

(define (cursor mode)        (list 'cursor mode))
(define (cursor? c)          (and (pair? c) (eq? (car c) 'cursor)))
(define (cursor-mode c)      (cadr c))

(define (alt-screen mode)    (list 'alt-screen mode))
(define (alt-screen? c)      (and (pair? c) (eq? (car c) 'alt-screen)))
(define (alt-screen-on? c)   (eq? (cadr c) 'on))

(define (mouse-mode mode)    (list 'mouse-mode mode))
(define (mouse-mode? c)      (and (pair? c) (eq? (car c) 'mouse-mode)))
(define (mouse-mode-kind c)  (cadr c))

(define (clear-screen)       'clear-screen)
(define (clear-screen? c)    (eq? c 'clear-screen))

(define (println . parts)    (cons 'println parts))
(define (println? c)         (and (pair? c) (eq? (car c) 'println)))
(define (println-parts c)    (cdr c))

(define (suspend)            'suspend-cmd)
(define (suspend? c)         (eq? c 'suspend-cmd))

(define* (exec command #:key on-done)
  (list 'exec command on-done))
(define (exec? c)            (and (pair? c) (eq? (car c) 'exec)))
(define (exec-command c)     (cadr c))
(define (exec-on-done c)     (caddr c))

(define (set-palette name)   (list 'set-palette name))
(define (set-palette? c)     (and (pair? c) (eq? (car c) 'set-palette)))
(define (set-palette-name c) (cadr c))

(define (cycle-palette)      'cycle-palette)
(define (cycle-palette? c)   (eq? c 'cycle-palette))

(define (clear-log)          'clear-log-cmd)
(define (clear-log? c)       (eq? c 'clear-log-cmd))

(define (focus w)            (list 'focus w))
(define (focus? c)           (and (pair? c) (eq? (car c) 'focus)))
(define (focus-target c)     (cadr c))

(define (cancel id)          (list 'cancel id))
(define (cancel? c)          (and (pair? c) (eq? (car c) 'cancel)))
(define (cancel-id c)        (cadr c))
