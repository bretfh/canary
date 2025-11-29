;;; components/textinput.scm --- Single-line text input

(define-module (tuition components textinput)
  #:use-module (tuition style)
  #:use-module (tuition protocol)
  #:use-module (tuition component)
  #:use-module (tuition text)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:use-module (oop goops)
  #:export (make-textinput
            textinput-value
            textinput-set-value!
            textinput-update
            textinput-view
            <textinput>))

;;; Textinput class
(define-class <textinput> (<component>)
  (value #:init-keyword #:value #:init-value "" #:accessor textinput-value)
  (cursor #:init-value 0 #:accessor textinput-cursor)
  (placeholder #:init-keyword #:placeholder #:init-value "" #:accessor textinput-placeholder)
  (prompt #:init-keyword #:prompt #:init-value "> " #:accessor textinput-prompt)
  (width #:init-keyword #:width #:init-value 20 #:accessor textinput-width)
  (char-limit #:init-keyword #:char-limit #:init-value 0 #:accessor textinput-char-limit))

(define* (make-textinput #:key (value "") (placeholder "") (prompt "> ") (width 20) (char-limit 0))
  "Create a new text input"
  (make <textinput>
    #:value value
    #:placeholder placeholder
    #:prompt prompt
    #:width width
    #:char-limit char-limit))

(define (textinput-set-value! input value)
  "Set input value"
  (set! (textinput-value input) value)
  (set! (textinput-cursor input) (string-length value))
  input)

;;; Update - handle key and mouse messages via component-update
(define (textinput-update input msg)
  "Update textinput with message, return (values input handled?)"
  (cond
   ;; Mouse click - position cursor
   ((and (is-a? msg <mouse-msg>) (eq? (action msg) 'press))
    (let* ((prompt-len (visible-length (textinput-prompt input)))
           (click-x (x msg))
           (rel-x (max 0 (- click-x prompt-len)))
           (val (textinput-value input))
           (new-pos (min rel-x (string-length val))))
      (set! (textinput-cursor input) new-pos)
      (values input #t)))

   ;; Key messages
   ((not (is-a? msg <key-msg>))
    (values input #f))
   (else
    (let ((k (key msg))
          (val (textinput-value input))
          (cur (textinput-cursor input))
          (limit (textinput-char-limit input)))
      (match k
          ('backspace
           (if (> cur 0)
               (let ((new-val (string-append (substring val 0 (1- cur))
                                           (substring val cur))))
                 (set! (textinput-value input) new-val)
                 (set! (textinput-cursor input) (1- cur))
                 (values input #t))
               (values input #t)))

          ('delete
           (if (< cur (string-length val))
               (let ((new-val (string-append (substring val 0 cur)
                                           (substring val (1+ cur)))))
                 (set! (textinput-value input) new-val)
                 (values input #t))
               (values input #t)))

          ('left
           (if (> cur 0)
               (begin
                 (set! (textinput-cursor input) (1- cur))
                 (values input #t))
               (values input #t)))

          ('right
           (if (< cur (string-length val))
               (begin
                 (set! (textinput-cursor input) (1+ cur))
                 (values input #t))
               (values input #t)))

          ('home
           (set! (textinput-cursor input) 0)
           (values input #t))

          ('end
           (set! (textinput-cursor input) (string-length val))
           (values input #t))

          ;; Regular character
          (_
           (if (and (char? k)
                   (or (zero? limit) (< (string-length val) limit)))
               (let ((new-val (string-append (substring val 0 cur)
                                           (string k)
                                           (substring val cur))))
                 (set! (textinput-value input) new-val)
                 (set! (textinput-cursor input) (1+ cur))
                 (values input #t))
               (values input #f))))))))

;;; Component protocol - delegate to textinput-update
(define-method (component-update (input <textinput>) msg)
  "Handle messages via component protocol"
  (textinput-update input msg))

;;; View - render textinput
(define (textinput-view input)
  "Render textinput to string"
  (let* ((val (textinput-value input))
         (prompt (textinput-prompt input))
         (width (textinput-width input))
         (cur (textinput-cursor input))
         (focused? (component-focused? input))
         (placeholder (textinput-placeholder input))
         (showing-placeholder? (and (string-null? val) (not (string-null? placeholder)))))

    (if showing-placeholder?
        ;; Placeholder mode - show cursor then placeholder
        (string-append prompt
                      (if focused?
                          (reverse-video " ")
                          "")
                      (fg placeholder 8))
        ;; Normal mode - show value with cursor
        (let* ((visible-start (max 0 (- cur (- width 5))))
               (visible-text (if (> (string-length val) width)
                                (substring val visible-start
                                         (min (string-length val)
                                              (+ visible-start width)))
                                val))
               (cursor-pos (- cur visible-start))
               (with-cursor (if (and focused? (>= cursor-pos 0) (<= cursor-pos (string-length visible-text)))
                               (string-append (substring visible-text 0 cursor-pos)
                                            (reverse-video (string (if (< cursor-pos (string-length visible-text))
                                                                     (string-ref visible-text cursor-pos)
                                                                     #\space)))
                                            (if (< cursor-pos (string-length visible-text))
                                                (substring visible-text (1+ cursor-pos))
                                                ""))
                               visible-text)))
          (string-append prompt with-cursor)))))
