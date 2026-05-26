;;; chat.scm — multi-widget composition demo.
;;;
;;; A scrollable history pane, a textinput at the bottom, and a fake
;;; message stream installed via (every) on <init>. Tab cycles focus
;;; between history (scroll with j/k) and input (typing). Enter posts
;;; your message and the fake bot replies after a delay.
;;;
;;; Run: guile -L /path/to/guile-canary examples/chat.scm
;;; Tab    switch focus between input and history
;;; j / k  scroll history (when history is focused)
;;; ↵      send (when input is focused)
;;; ctrl-c quit

(use-modules (canary)
             (canary components panel)
             (canary components textinput)
             (canary components viewport)
             (oop goops))

(define %bot-names '("nora" "kai" "rin" "atlas"))
(define %bot-quips
  '("oh interesting"
    "say more about that"
    "hm"
    "i was just thinking the same thing"
    "have you tried turning it off and on again"
    "wait, really?"
    "🤔"
    "agreed"
    "lol"
    "this is fine"))

(define (random-element xs) (list-ref xs (random (length xs))))

(define-class <bot-tick> ())

(define-class <chat> ()
  (history  #:init-form (viewport #:step 1 #:from 'bottom)
            #:accessor chat-history)
  (input    #:init-form (textinput #:prompt "> "
                                   #:placeholder "say something"
                                   #:width 60
                                   #:focused? #t)
            #:accessor chat-input)
  (focus-on #:init-value 'input  #:accessor chat-focus-on))

(define (chat-append-line! c face name text)
  (let* ((line (hbox (txt (string-append name ": ") #:fg face #:bold)
                     (txt text)))
         (vp   (chat-history c)))
    (set! (viewport-items vp)
          (append (viewport-items vp) (list line)))))

(define (post-user-msg! c text)
  (chat-append-line! c 'accent "you" text))

(define (post-bot-msg! c)
  (chat-append-line! c 'note
                     (random-element %bot-names)
                     (random-element %bot-quips)))

(define (focus-cmd-for c)
  (case (chat-focus-on c)
    ((input)   (focus (chat-input   c)))
    ((history) (focus (chat-history c)))
    (else      #f)))

(define-method (view (c <chat>))
  (vbox
   (flex (boxed (align (chat-history c) #:v 'bottom)
                #:title (case (chat-focus-on c)
                          ((history) " chat — history focused (tab to type) ")
                          (else      " chat "))
                #:fg (case (chat-focus-on c)
                       ((history) 'accent)
                       (else      'muted)))
         #:shrink 1)
   (flex (boxed (chat-input c)
                #:title (case (chat-focus-on c)
                          ((input)  " input — tab to scroll history ")
                          (else     " input "))
                #:fg (case (chat-focus-on c)
                       ((input) 'accent)
                       (else    'muted)))
         #:grow 0)))

(define-method (update (c <chat>) (msg <init>))
  ;; Greet, install the bot, focus the input.
  (chat-append-line! c 'muted "system" "welcome — type and press enter")
  (batch (focus (chat-input c))
         (every #:seconds 4
                #:id 'bot-stream
                (lambda () (make <bot-tick>)))))

(define (enter-key? k)
  (or (eq? k 'enter) (eq? k 'return)
      (eqv? k #\newline) (eqv? k #\return)))

(define-method (update (c <chat>) (msg <key>))
  (let ((k (key-sym msg)))
    (cond
     ((eq? k 'escape) 'quit)
     ((eq? k 'tab)
      (set! (chat-focus-on c)
            (case (chat-focus-on c)
              ((input)   'history)
              ((history) 'input)
              (else      'input)))
      (set! (textinput-focused? (chat-input c)) (eq? (chat-focus-on c) 'input))
      (focus-cmd-for c))
     ((and (eq? (chat-focus-on c) 'input) (enter-key? k))
      (let ((val (textinput-value (chat-input c))))
        (unless (zero? (string-length val))
          (post-user-msg! c val)
          (set! (textinput-value (chat-input c)) "")
          (set! (textinput-cursor (chat-input c)) 0)))))))

(define-method (update (c <chat>) (msg <bot-tick>))
  (post-bot-msg! c))

(run-app (make <chat>)
         #:title  "chat"
         #:keymap (keymap (bind '(#\c ctrl) 'quit))
         #:mouse  'off)
