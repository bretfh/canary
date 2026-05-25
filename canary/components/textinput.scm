(define-module (canary components textinput)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary protocol)
  #:use-module (canary key)
  #:use-module (ice-9 match)
  #:use-module (oop goops)
  #:export (<textinput>
            textinput?
            make-textinput
            textinput-value
            textinput-cursor
            textinput-placeholder
            textinput-prompt
            textinput-width
            textinput-char-limit
            textinput-focused?))

(define-class <textinput> ()
  (value       #:init-keyword #:value       #:init-value ""
               #:accessor textinput-value)
  (cursor      #:init-keyword #:cursor      #:init-value 0
               #:accessor textinput-cursor)
  (placeholder #:init-keyword #:placeholder #:init-value ""
               #:accessor textinput-placeholder)
  (prompt      #:init-keyword #:prompt      #:init-value "> "
               #:accessor textinput-prompt)
  (width       #:init-keyword #:width       #:init-value 20
               #:accessor textinput-width)
  (char-limit  #:init-keyword #:char-limit  #:init-value 0
               #:accessor textinput-char-limit)
  (focused?    #:init-keyword #:focused?    #:init-value #f
               #:accessor textinput-focused?))

(define (textinput? x) (is-a? x <textinput>))
(define (make-textinput . args) (apply make <textinput> args))

(define-method (view (ti <textinput>) sz)
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

(define-method (update (ti <textinput>) msg sz)
  (cond
   ((and (mouse? msg) (eq? (mouse-action msg) 'press))
    (let* ((pl  (string-length (textinput-prompt ti)))
           (rel (max 0 (- (mouse-x msg) pl)))
           (new (min rel (string-length (textinput-value ti)))))
      (set! (textinput-cursor ti) new))
    (values ti #f))
   ((key? msg)
    (let ((k     (key-sym msg))
          (val   (textinput-value ti))
          (cur   (textinput-cursor ti))
          (limit (textinput-char-limit ti)))
      (match k
        ('backspace
         (when (> cur 0)
           (set! (textinput-value ti)
                 (string-append (substring val 0 (- cur 1))
                                (substring val cur)))
           (set! (textinput-cursor ti) (- cur 1))))
        ('delete
         (when (< cur (string-length val))
           (set! (textinput-value ti)
                 (string-append (substring val 0 cur)
                                (substring val (+ cur 1))))))
        ('left  (when (> cur 0) (set! (textinput-cursor ti) (- cur 1))))
        ('right (when (< cur (string-length val))
                  (set! (textinput-cursor ti) (+ cur 1))))
        ('home  (set! (textinput-cursor ti) 0))
        ('end   (set! (textinput-cursor ti) (string-length val)))
        (_
         (when (and (char? k)
                    (or (zero? limit) (< (string-length val) limit)))
           (set! (textinput-value ti)
                 (string-append (substring val 0 cur)
                                (string k)
                                (substring val cur)))
           (set! (textinput-cursor ti) (+ cur 1)))))
      (values ti #f)))
   (else (values ti #f))))
