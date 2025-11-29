;;; protocol.scm --- TEA protocol messages and types

(define-module (tuition protocol)
  #:use-module (oop goops)
  #:export (<key-msg>
            <quit-msg>
            <window-size-msg>
            <mouse-msg>
            key
            alt
            ctrl
            width
            height
            x
            y
            button
            action
            quit-cmd
            batch-cmd
            sequence-cmd))

;;; Key message
(define-class <key-msg> ()
  (key #:init-keyword #:key #:accessor key)
  (alt #:init-keyword #:alt #:init-value #f #:accessor alt)
  (ctrl #:init-keyword #:ctrl #:init-value #f #:accessor ctrl))

;;; Quit message
(define-class <quit-msg> ())

;;; Window size message
(define-class <window-size-msg> ()
  (width #:init-keyword #:width #:accessor width)
  (height #:init-keyword #:height #:accessor height))

;;; Mouse message
(define-class <mouse-msg> ()
  (x #:init-keyword #:x #:accessor x)
  (y #:init-keyword #:y #:accessor y)
  (button #:init-keyword #:button #:accessor button)
  (action #:init-keyword #:action #:accessor action))

;;; Commands (functions that return messages or #f)
(define (quit-cmd)
  "Return a command that quits the program"
  (lambda () (make <quit-msg>)))

(define (batch-cmd . cmds)
  "Run multiple commands concurrently"
  (cons 'batch cmds))

(define (sequence-cmd . cmds)
  "Run multiple commands in sequence"
  (cons 'sequence cmds))
