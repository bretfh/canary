(define-module (canary components textinput)
  #:use-module (canary node)
  #:use-module (canary layout)
  #:use-module (canary protocol)
  #:use-module (canary key)
  #:use-module (ice-9 match)
  #:export (<textinput-state>
            textinput?
            make-textinput
            textinput-value
            textinput-cursor
            textinput-placeholder
            textinput-prompt
            textinput-width
            textinput-char-limit
            textinput-focused?))

(define-node textinput
  #:state ((value "")
           (cursor 0)
           (placeholder "")
           (prompt "> ")
           (width 20)
           (char-limit 0)
           (focused? #f))
  #:view
  (lambda (ti)
    (let* ((val (textinput-value ti))
           (prompt (textinput-prompt ti))
           (w (textinput-width ti))
           (cur (textinput-cursor ti))
           (focused? (textinput-focused? ti))
           (ph (textinput-placeholder ti))
           (showing-ph? (and (string-null? val) (not (string-null? ph)))))
      (cond
       (showing-ph?
        (hbox (txt prompt)
              (if focused? (txt " " #:reverse) (txt ""))
              (txt ph #:fg 'placeholder)))
       (else
        (let* ((start (max 0 (- cur (- w 5))))
               (visible (if (> (string-length val) w)
                            (substring val start (min (string-length val) (+ start w)))
                            val))
               (cpos (- cur start)))
          (cond
           ((and focused? (>= cpos 0) (<= cpos (string-length visible)))
            (let ((left (substring visible 0 cpos))
                  (cell (if (< cpos (string-length visible))
                            (string (string-ref visible cpos))
                            " "))
                  (right (if (< cpos (string-length visible))
                             (substring visible (+ cpos 1))
                             "")))
              (hbox (txt prompt) (txt left) (txt cell #:reverse) (txt right))))
           (else (hbox (txt prompt) (txt visible)))))))))
  #:react
  (lambda (ti msg)
    (cond
     ((and (mouse? msg) (eq? (mouse-action msg) 'press))
      (let* ((pl (string-length (textinput-prompt ti)))
             (rel (max 0 (- (mouse-x msg) pl)))
             (new-pos (min rel (string-length (textinput-value ti)))))
        (set! (textinput-cursor ti new-pos)))
     ((key? msg)
      (let ((k (key-sym msg))
            (val (textinput-value ti))
            (cur (textinput-cursor ti))
            (limit (textinput-char-limit ti)))
        (match k
          ('backspace
           (when (> cur 0)
             (set! (textinput-value ti (string-append (substring val 0 (- cur 1))
                                                    (substring val cur)))
             (set! (textinput-cursor ti (- cur 1))))
          ('delete
           (when (< cur (string-length val))
             (set! (textinput-value ti (string-append (substring val 0 cur)
                                                    (substring val (+ cur 1))))))
          ('left  (when (> cur 0) (set! (textinput-cursor ti (- cur 1))))
          ('right (when (< cur (string-length val)) (set! (textinput-cursor ti (+ cur 1))))
          ('home  (set! (textinput-cursor ti 0))
          ('end   (set! (textinput-cursor ti (string-length val)))
          (_
           (when (and (char? k) (or (zero? limit) (< (string-length val) limit)))
             (set! (textinput-value ti (string-append (substring val 0 cur)
                                                    (string k)
                                                    (substring val cur)))
             (set! (textinput-cursor ti (+ cur 1))))))))))
