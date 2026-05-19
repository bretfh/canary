(define-module (canary backend-ansi)
  #:use-module (canary backend)
  #:use-module (canary draw)
  #:use-module (canary faces)
  #:use-module (canary protocol)
  #:use-module (canary terminal)
  #:use-module ((canary term types) #:prefix t:)
  #:use-module ((canary term ops) #:prefix t:)
  #:use-module ((canary term write) #:prefix t:)
  #:use-module ((canary term render) #:prefix t:)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<ansi-backend>
            make-ansi-backend
            ansi-backend-faces
            ansi-backend-port
            face->sgr
            cmds->ansi
            render-cmds-to-term!))

(define-class <ansi-backend> (<backend>)
  (port      #:init-keyword #:port  #:accessor ansi-backend-port)
  (faces     #:init-keyword #:faces #:accessor ansi-backend-faces)
  (size      #:init-keyword #:size  #:init-value (size 80 24) #:accessor ansi-backend-size)
  (cur-term  #:init-value #f #:accessor ansi-backend-cur-term)
  (prev-term #:init-value #f #:accessor ansi-backend-prev-term))

(define* (make-ansi-backend #:key (port (current-output-port))
                            (faces default-faces))
  (make <ansi-backend> #:port port #:faces faces))

(define (hex->rgb hex)
  (let ((h (if (and (>= (string-length hex) 1)
                    (char=? (string-ref hex 0) #\#))
               (substring hex 1) hex)))
    (cond
     ((= (string-length h) 6)
      (list (string->number (substring h 0 2) 16)
            (string->number (substring h 2 4) 16)
            (string->number (substring h 4 6) 16)))
     (else '(255 255 255)))))

(define (sgr-fg-rgb hex)
  (let ((rgb (hex->rgb hex)))
    (string-append "38;2;" (number->string (car rgb)) ";"
                   (number->string (cadr rgb)) ";"
                   (number->string (caddr rgb)))))

(define (sgr-bg-rgb hex)
  (let ((rgb (hex->rgb hex)))
    (string-append "48;2;" (number->string (car rgb)) ";"
                   (number->string (cadr rgb)) ";"
                   (number->string (caddr rgb)))))

(define (attr->sgr a)
  (case a
    ((bold) "1") ((dim) "2") ((italic) "3") ((underline) "4")
    ((blink) "5") ((reverse) "7") ((strikethrough) "9")
    (else #f)))

(define (face->sgr face extra-attrs)
  (cond
   ((not face) "\x1b[0m")
   (else
    (let* ((parts '())
           (attrs (append (or (face-attrs face) '()) (or extra-attrs '())))
           (parts (fold (lambda (a acc)
                          (let ((s (attr->sgr a)))
                            (if s (cons s acc) acc)))
                        parts attrs))
           (parts (if (face-fg face) (cons (sgr-fg-rgb (face-fg face)) parts) parts))
           (parts (if (face-bg face) (cons (sgr-bg-rgb (face-bg face)) parts) parts)))
      (cond
       ((null? parts) "\x1b[0m")
       (else (string-append "\x1b[" (string-join parts ";" 'infix) "m")))))))

(define (apply-face-to-term-attrs! tattrs face extra-attrs)
  (t:reset-face-attrs! tattrs)
  (when face
    (when (face-fg face)
      (t:set-face-fg! tattrs (hex->rgb (face-fg face))))
    (when (face-bg face)
      (t:set-face-bg! tattrs (hex->rgb (face-bg face))))
    (for-each
     (lambda (a)
       (case a
         ((bold) (t:set-face-bold! tattrs #t))
         ((dim faint) (t:set-face-faint! tattrs #t))
         ((italic) (t:set-face-italic! tattrs #t))
         ((underline) (t:set-face-underline! tattrs 'single))
         ((blink) (t:set-face-blink! tattrs 'slow))
         ((reverse) (t:set-face-inverse! tattrs #t))
         ((strikethrough) (t:set-face-crossed! tattrs #t))))
     (append (or (face-attrs face) '()) (or extra-attrs '())))))

(define (render-cmds-to-term! term cmds face-table)
  (for-each
   (lambda (cmd)
     (cond
      ((clear-cmd? cmd)
       (t:reset-face-attrs! (t:term-attrs term))
       (t:term-erase-in-display! term 2)
       (t:term-goto! term 1 1))
      ((text-cmd? cmd)
       (let ((face (face-table-lookup face-table (text-face cmd))))
         (apply-face-to-term-attrs! (t:term-attrs term) face (text-attrs cmd))
         (t:term-goto! term (+ (text-row cmd) 1) (+ (text-col cmd) 1))
         (t:term-write! term (text-str cmd))))
      ((fill-cmd? cmd)
       (let* ((face (face-table-lookup face-table (fill-face cmd)))
              (w (fill-w cmd))
              (h (fill-h cmd))
              (line (make-string w #\space)))
         (apply-face-to-term-attrs! (t:term-attrs term) face '())
         (do ((r 0 (+ r 1)))
             ((= r h))
           (t:term-goto! term (+ (fill-row cmd) r 1) (+ (fill-col cmd) 1))
           (t:term-write! term line))))
      ((cursor-cmd? cmd)
       (t:term-goto! term (+ (cursor-row cmd) 1) (+ (cursor-col cmd) 1)))
      (else #f)))
   cmds))

(define (cmds-extent cmds)
  (let lp ((cs cmds) (mw 1) (mh 1))
    (cond
     ((null? cs) (cons mw mh))
     (else
      (let ((c (car cs)))
        (cond
         ((text-cmd? c)
          (lp (cdr cs)
              (max mw (+ (text-col c) (string-length (text-str c))))
              (max mh (+ (text-row c) 1))))
         ((fill-cmd? c)
          (lp (cdr cs)
              (max mw (+ (fill-col c) (fill-w c)))
              (max mh (+ (fill-row c) (fill-h c)))))
         ((cursor-cmd? c)
          (lp (cdr cs)
              (max mw (+ (cursor-col c) 1))
              (max mh (+ (cursor-row c) 1))))
         (else (lp (cdr cs) mw mh))))))))

(define* (cmds->ansi cmds faces #:key cols rows)
  (let* ((ext (cmds-extent cmds))
         (w (or cols (car ext)))
         (h (or rows (cdr ext)))
         (term (t:make-term #:width w #:height h)))
    (render-cmds-to-term! term cmds faces)
    (t:term-diff->ansi #f term)))

(define +sync-begin+ "\x1b[?2026h")
(define +sync-end+ "\x1b[?2026l")

(define (ensure-term-size! b w h)
  "Ensure the backend's cur and prev terms exist at WxH. Resize or
allocate as needed. Returns nothing — mutates the backend."
  (let ((cur  (ansi-backend-cur-term b))
        (prev (ansi-backend-prev-term b)))
    (cond
     ((not cur)
      (set! (ansi-backend-cur-term b)  (t:make-term #:width w #:height h))
      (set! (ansi-backend-prev-term b) (t:make-term #:width w #:height h)))
     ((or (not (= (t:term-width cur) w))
          (not (= (t:term-height cur) h)))
      (t:term-resize! cur w h)
      (t:term-resize! prev w h)
      ;; force a full repaint after resize by zeroing prev
      (t:term-clear! prev)))))

(define-method (backend-draw (b <ansi-backend>) cmds)
  (let* ((sz   (get-terminal-size))
         (cur-sz (ansi-backend-size b))
         (w    (if sz (size-width sz)  (size-width cur-sz)))
         (h    (if sz (size-height sz) (size-height cur-sz)))
         (out  (ansi-backend-port b)))
    (ensure-term-size! b w h)
    (let ((cur  (ansi-backend-cur-term b))
          (prev (ansi-backend-prev-term b)))
      (t:term-clear! cur)
      (render-cmds-to-term! cur cmds (ansi-backend-faces b))
      (display +sync-begin+ out)
      (display (t:term-diff->ansi prev cur) out)
      (display +sync-end+ out)
      (force-output out)
      ;; swap cur and prev: this frame's cur becomes next frame's prev,
      ;; last frame's prev gets recycled as next frame's cur.
      (set! (ansi-backend-cur-term  b) prev)
      (set! (ansi-backend-prev-term b) cur)
      (unless (and (= (size-width cur-sz) w) (= (size-height cur-sz) h))
        (set! (ansi-backend-size b) (size w h))))))

(define-method (backend-init (b <ansi-backend>))
  (enter-raw-mode)
  (enter-alternate-screen)
  (hide-cursor)
  (let ((sz (get-terminal-size)))
    (set! (ansi-backend-size b) sz)
    (set! (ansi-backend-cur-term b)  #f)
    (set! (ansi-backend-prev-term b) #f)))

(define-method (backend-shutdown (b <ansi-backend>))
  (show-cursor)
  (exit-alternate-screen)
  (exit-raw-mode))

(define-method (backend-size (b <ansi-backend>))
  (or (get-terminal-size) (ansi-backend-size b)))
