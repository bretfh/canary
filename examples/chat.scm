;;; chat.scm — composition of two nodes: a message list and an input.
;;;
;;; Run: guile -L /path/to/guile-canary examples/chat.scm
;;; Type a line and press enter. ctrl-c to quit.

(use-modules (canary)
             (canary components panel)
             (canary components textinput)
             (oop goops))

(define-class <chat> ()
  (lines #:init-value '() #:accessor chat-lines)
  (input #:init-form (make-textinput #:prompt "> "
                                     #:placeholder "say something"
                                     #:width 40
                                     #:focused? #t)
         #:accessor chat-input))

(define-method (view (c <chat>) sz)
  (let ((ls (chat-lines c)))
    (vbox
     (make-panel #:title "chat" #:face 'muted
                 #:content
                 (cond
                  ((null? ls)
                   (txt "(no messages yet — type below)"
                        #:fg 'muted #:italic))
                  (else
                   (apply vbox
                          (map (lambda (line)
                                 (hbox (txt "▸ " #:fg 'accent)
                                       (txt line)))
                               (reverse ls))))))
     (spacer 1)
     (view (chat-input c) sz))))

(define-method (update (c <chat>) (msg <key>) sz)
  (let ((k (key-sym msg)))
    (cond
     ((or (eq? k 'return) (eqv? k #\newline) (eqv? k #\return))
      (let ((val (textinput-value (chat-input c))))
        (unless (zero? (string-length val))
          (set! (chat-lines c) (cons val (chat-lines c)))
          (set! (textinput-value (chat-input c)) "")
          (set! (textinput-cursor (chat-input c)) 0)))
      (values c #f))
     (else
      (update (chat-input c) msg sz)
      (values c #f)))))

(define-method (update (c <chat>) msg sz)
  (update (chat-input c) msg sz)
  (values c #f))

(run-app (make <chat>)
         #:title  "chat"
         #:keymap (keymap (bind '(#\c ctrl) 'quit))
         #:mouse  'off)
