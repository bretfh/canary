(define-module (canary components panel)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary borders)
  #:use-module (oop goops)
  #:export (<panel>
            panel?
            make-panel
            panel-title
            panel-footer
            panel-border
            panel-face
            panel-hover-face
            panel-hover-border
            panel-content))

(define-class <panel> ()
  (title         #:init-keyword #:title         #:init-value #f
                 #:accessor panel-title)
  (footer        #:init-keyword #:footer        #:init-value #f
                 #:accessor panel-footer)
  (border        #:init-keyword #:border        #:init-value border-rounded
                 #:accessor panel-border)
  (face          #:init-keyword #:face          #:init-value 'muted
                 #:accessor panel-face)
  (hover-face    #:init-keyword #:hover-face    #:init-value #f
                 #:accessor panel-hover-face)
  (hover-border  #:init-keyword #:hover-border  #:init-value #f
                 #:accessor panel-hover-border)
  (content       #:init-keyword #:content       #:init-value #f
                 #:accessor panel-content))

(define (panel? x) (is-a? x <panel>))
(define (make-panel . args) (apply make <panel> args))

(define-method (view (p <panel>) sz)
  (let* ((base-face (panel-face p))
         (border    (panel-border p))
         (hf        (panel-hover-face p))
         (hb        (or (panel-hover-border p) border))
         (body      (or (panel-content p) (txt "")))
         (footer    (panel-footer p))
         (with-footer
          (lambda (face)
            (if footer
                (vbox body (txt footer #:fg face #:italic))
                body)))
         (frame
          (lambda (face brd)
            (boxed (with-footer face)
                   #:border brd
                   #:fg     face
                   #:title  (panel-title p)))))
    (if hf
        (on-hover (frame base-face border)
                  (lambda (_) (frame hf hb)))
        (frame base-face border))))
