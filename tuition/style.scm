;;; style.scm --- ANSI colors and attributes

(define-module (tuition style)
  #:use-module (tuition terminal)
  #:export (bold
            italic
            underline
            strikethrough
            reverse-video
            fg
            bg
            reset))

(define (bold str)
  (string-append (csi "1m") str (csi "0m")))

(define (italic str)
  (string-append (csi "3m") str (csi "0m")))

(define (underline str)
  (string-append (csi "4m") str (csi "0m")))

(define (strikethrough str)
  (string-append (csi "9m") str (csi "0m")))

(define (reverse-video str)
  (string-append (csi "7m") str (csi "0m")))

(define (hex->rgb hex-str)
  (let ((hex (if (string-prefix? "#" hex-str)
                 (substring hex-str 1)
                 hex-str)))
    (cond
     ((= (string-length hex) 6)
      (list (string->number (substring hex 0 2) 16)
            (string->number (substring hex 2 4) 16)
            (string->number (substring hex 4 6) 16)))
     ((= (string-length hex) 3)
      (let ((r (substring hex 0 1))
            (g (substring hex 1 2))
            (b (substring hex 2 3)))
        (list (string->number (string-append r r) 16)
              (string->number (string-append g g) 16)
              (string->number (string-append b b) 16))))
     (else '(255 255 255)))))

(define (fg str color)
  (cond
   ((string? color)
    (let ((rgb (hex->rgb color)))
      (string-append (csi "38;2;" (number->string (car rgb)) ";"
                          (number->string (cadr rgb)) ";"
                          (number->string (caddr rgb)) "m")
                     str
                     (csi "0m"))))
   ((list? color)
    (string-append (csi "38;2;" (number->string (car color)) ";"
                        (number->string (cadr color)) ";"
                        (number->string (caddr color)) "m")
                   str
                   (csi "0m")))
   (else str)))

(define (bg str color)
  (cond
   ((string? color)
    (let ((rgb (hex->rgb color)))
      (string-append (csi "48;2;" (number->string (car rgb)) ";"
                          (number->string (cadr rgb)) ";"
                          (number->string (caddr rgb)) "m")
                     str
                     (csi "0m"))))
   ((list? color)
    (string-append (csi "48;2;" (number->string (car color)) ";"
                        (number->string (cadr color)) ";"
                        (number->string (caddr color)) "m")
                   str
                   (csi "0m")))
   (else str)))

(define reset (csi "0m"))
