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
            textinput-focused?))

(define-class <textinput> (<focusable>)
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
  "Render <textinput> TI: the prompt followed by the value or, if
empty, the placeholder.  When focused, draws a reverse-video cell
at the cursor position; horizontally scrolls when value length
exceeds width."
  (let* ((val      (textinput-value ti))
         (prompt   (textinput-prompt ti))
         (w        (textinput-width ti))
         (cur      (textinput-cursor ti))
         (focused? (textinput-focused? ti))
         (ph       (textinput-placeholder ti)))
    (cond
     ((and (string-null? val) (not (string-null? ph)))
      (hbox (txt prompt)
            (if focused? (txt " " #:reverse) (txt ""))
            (txt ph #:fg 'placeholder)))
     (else
      (let* ((start   (max 0 (- cur (- w 5))))
             (visible (if (> (string-length val) w)
                          (substring val start
                                     (min (string-length val) (+ start w)))
                          val))
             (cpos    (- cur start)))
        (if (and focused? (>= cpos 0) (<= cpos (string-length visible)))
            (let ((left  (substring visible 0 cpos))
                  (cell  (if (< cpos (string-length visible))
                             (string (string-ref visible cpos))
                             " "))
                  (right (if (< cpos (string-length visible))
                             (substring visible (+ cpos 1))
                             "")))
              (hbox (txt prompt) (txt left)
                    (txt cell #:reverse) (txt right)))
            (hbox (txt prompt) (txt visible))))))))

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
self-inserting chars (subject to char-limit when non-zero)."
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
     #f)))
