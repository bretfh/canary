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

(define-class <chat> (<focusable>)
  (history  #:init-form (viewport #:step 1 #:from 'bottom)
            #:getter chat-history)
  (input    #:init-form (textinput #:prompt "> "
                                   #:placeholder "say something"
                                   #:width 60
                                   #:focused? #t)
            #:getter chat-input)
  (focus-on #:init-value 'input  #:getter chat-focus-on))

(define (chat-append-line c face name text)
  "Return C with a new line appended to its history.  FACE styles
the speaker's name, NAME is the speaker, TEXT is the message body."
  (let* ((line (hbox (txt (string-append name ": ") #:fg face #:bold)
                     (txt text)))
         (vp   (chat-history c)))
    (update-slots c
      #:history (update-slots vp
                  #:items (append (viewport-items vp) (list line))))))

(define (post-user-msg c text)
  (chat-append-line c 'accent "you" text))

(define (post-bot-msg c)
  (chat-append-line c 'note
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
  (let ((greeted (chat-append-line c 'muted "system"
                                   "welcome — type and press enter")))
    (cons greeted
          (batch (focus (chat-input greeted))
                 (every #:seconds 4
                        #:id 'bot-stream
                        (lambda () (make <bot-tick>)))))))

(define (enter-key? k)
  (or (eq? k 'enter) (eq? k 'return)
      (eqv? k #\newline) (eqv? k #\return)))

(define-method (update (c <chat>) (msg <key>))
  (let ((k (key-sym msg)))
    (cond
     ((eq? k 'escape) (cons c 'quit))
     ((eq? k 'tab)
      (let* ((next (case (chat-focus-on c)
                     ((input)   'history)
                     ((history) 'input)
                     (else      'input)))
             (new-input (update-slots (chat-input c)
                          #:focused? (eq? next 'input)))
             (new-c (update-slots c #:focus-on next #:input new-input)))
        (cons new-c
              (case next
                ((input)   (focus (chat-input new-c)))
                ((history) (focus (chat-history new-c)))
                (else      #f)))))
     ((and (eq? (chat-focus-on c) 'input) (enter-key? k))
      (let ((val (textinput-value (chat-input c))))
        (cond
         ((zero? (string-length val)) (cons c #f))
         (else
          (let* ((posted (post-user-msg c val)))
            (cons (update-slots posted
                    #:input (update-slots (chat-input posted)
                              #:value ""
                              #:cursor 0))
                  #f))))))
     (else (cons c #f)))))

(define-method (update (c <chat>) (msg <bot-tick>))
  (cons (post-bot-msg c) #f))

(run-app (make <chat>)
         #:title  "chat"
         #:keymap (keymap (bind '(#\c ctrl) 'quit))
         #:mouse  'off)
