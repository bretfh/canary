(define-module (canary components textinput)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary protocol)
  #:use-module (canary key)
  #:use-module (canary widget)
  #:use-module (ice-9 match)
  #:use-module (oop goops)
  #:export (<textinput>
            textinput?
            textinput
            textinput-value
            textinput-cursor
            textinput-placeholder
            textinput-prompt
            textinput-width
            textinput-char-limit
            textinput-mask?
            textinput-focused?))

(define-component <textinput>
  (value       #:init-keyword #:value       #:init-value ""
               #:getter textinput-value)
  (cursor      #:init-keyword #:cursor      #:init-value 0
               #:getter textinput-cursor)
  (placeholder #:init-keyword #:placeholder #:init-value ""
               #:getter textinput-placeholder)
  (prompt      #:init-keyword #:prompt      #:init-value "> "
               #:getter textinput-prompt)
  (width       #:init-keyword #:width       #:init-value 20
               #:getter textinput-width)
  (char-limit  #:init-keyword #:char-limit  #:init-value 0
               #:getter textinput-char-limit)
  (mask?       #:init-keyword #:mask?       #:init-value #f
               #:getter textinput-mask?)
  (focused?    #:init-keyword #:focused?    #:init-value #f
               #:getter textinput-focused?))

(define (textinput? x)
  "Return #t if X is a <textinput>."
  (is-a? x <textinput>))

(define (textinput . args)
  "Return a fresh <textinput> initialised from ARGS, a sequence of
#:value, #:cursor, #:placeholder, #:prompt, #:width, #:char-limit,
#:focused? keyword arguments."
  (apply make <textinput> args))

(define-method (view (ti <textinput>))
  "Render <textinput> TI: the prompt followed by the value (or
placeholder when empty), with a cursor cell always visible so the
field reads as an input target at a glance.  Unfocused → static
reverse-video cell at the cursor position.  Focused → same cell plus
a `place-cursor` (spliced into the hbox at the cursor column) so the
terminal's hardware cursor sits on top and blinks naturally.  The
cursor node is a 0-width hbox child; it inherits the column of the
next sibling, which is exactly where we want the caret."
  (let* ((raw      (textinput-value ti))
         (val      (if (textinput-mask? ti)
                       (make-string (string-length raw) #\•)
                       raw))
         (prompt   (textinput-prompt ti))
         (w        (textinput-width ti))
         (cur      (textinput-cursor ti))
         (focused? (textinput-focused? ti))
         (ph       (textinput-placeholder ti)))
    (define cursor-mark (place-cursor 0 0 #:style 'block))
    (cond
     ((string-null? val)
      ;; Empty field: prompt + (cursor when focused) + placeholder.
      ;; Unfocused empty input shows just the placeholder (no trailing
      ;; reverse-video cell that reads as a stray black square in the
      ;; UI).
      (if focused?
          (hbox (txt prompt) cursor-mark
                (txt " " #:reverse) (txt ph #:fg 'placeholder))
          (hbox (txt prompt) (txt ph #:fg 'placeholder))))
     (else
      (let* ((start   (max 0 (- cur (- w 5))))
             (visible (if (> (string-length val) w)
                          (substring val start
                                     (min (string-length val) (+ start w)))
                          val))
             (cpos    (- cur start)))
        (cond
         ((and focused? (>= cpos 0) (<= cpos (string-length visible)))
          (let ((left  (substring visible 0 cpos))
                (cell  (if (< cpos (string-length visible))
                           (string (string-ref visible cpos))
                           " "))
                (right (if (< cpos (string-length visible))
                           (substring visible (+ cpos 1))
                           "")))
            (hbox (txt prompt) (txt left) cursor-mark
                  (txt cell #:reverse) (txt right))))
         (else
          ;; Unfocused with content: just the prompt + value, no
          ;; trailing block.  The previous reverse-video cell was a
          ;; "where the cursor would land" affordance but visually
          ;; reads as a stray square.
          (hbox (txt prompt) (txt visible)))))))))

(define-method (consumes-keys? (ti <textinput>)) #t)

(define-method (update (ti <textinput>) (msg <focus-in>))
  "Engine dispatches <focus-in> when this textinput joins the focus
chain.  Mirror it in the focused? slot so the next render shows the
cursor cell + place-cursor node and the next <key> can write text.
Also flip the engine's cursor mode visible/block so the terminal's
hardware cursor parks at place-cursor's position and blinks."
  (cons (update-slots ti #:focused? #t)
        (batch (cursor 'visible) (cursor 'block))))

(define-method (update (ti <textinput>) (msg <focus-out>))
  "Inverse of <focus-in>: this textinput just left the focus chain."
  (cons (update-slots ti #:focused? #f)
        (cursor 'hidden)))

(define-method (update (ti <textinput>) (msg <mouse>))
  "Mouse press repositions the cursor.  Other mouse actions are
ignored."
  (cond
   ((eq? (mouse-action msg) 'press)
    (let* ((pl  (string-length (textinput-prompt ti)))
           (rel (max 0 (- (mouse-x msg) pl)))
           (new (min rel (string-length (textinput-value ti)))))
      (cons (update-slots ti #:cursor new) #f)))
   (else (cons ti #f))))

(define-method (update (ti <textinput>) (msg <key>))
  "Keys handled: backspace, delete, left, right, home, end, and
self-inserting chars (subject to char-limit when non-zero).

Only acts on `'press` events.  Kitty's report-event-types flag also
delivers `'release` and `'repeat`; honouring those would insert each
typed letter twice on terminals whose OS auto-repeat fires before
release lands."
  (cond
   ((not (eq? (key-event msg) 'press)) (cons ti #f))
   (else
  (let ((k     (key-sym msg))
        (val   (textinput-value ti))
        (cur   (textinput-cursor ti))
        (limit (textinput-char-limit ti)))
    (cons
     (match k
       ('backspace
        (cond
         ((zero? cur) ti)
         (else (update-slots ti
                 #:value  (string-append (substring val 0 (- cur 1))
                                         (substring val cur))
                 #:cursor (- cur 1)))))
       ('delete
        (cond
         ((>= cur (string-length val)) ti)
         (else (update-slots ti
                 #:value (string-append (substring val 0 cur)
                                        (substring val (+ cur 1)))))))
       ('left  (cond ((zero? cur) ti)
                     (else (update-slots ti #:cursor (- cur 1)))))
       ('right (cond ((>= cur (string-length val)) ti)
                     (else (update-slots ti #:cursor (+ cur 1)))))
       ('home  (update-slots ti #:cursor 0))
       ('end   (update-slots ti #:cursor (string-length val)))
       (_
        (cond
         ((and (char? k)
               (or (zero? limit) (< (string-length val) limit)))
          (update-slots ti
            #:value  (string-append (substring val 0 cur)
                                    (string k)
                                    (substring val cur))
            #:cursor (+ cur 1)))
         (else ti))))
     #f)))))
