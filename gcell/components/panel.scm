(define-module (gcell components panel)
  #:use-module (gcell view)
  #:use-module (gcell layout)
  #:use-module (gcell borders)
  #:use-module (gcell widget)
  #:use-module (oop goops)
  #:export (<panel>
            panel?
            panel
            panel-title
            panel-footer
            panel-border
            panel-face
            panel-hover-face
            panel-hover-border
            panel-content))

(define-class <panel> (<focusable>)
  (title         #:init-keyword #:title         #:init-value #f
                 #:getter panel-title)
  (footer        #:init-keyword #:footer        #:init-value #f
                 #:getter panel-footer)
  (border        #:init-keyword #:border        #:init-value border-rounded
                 #:getter panel-border)
  (face          #:init-keyword #:face          #:init-value 'muted
                 #:getter panel-face)
  (hover-face    #:init-keyword #:hover-face    #:init-value #f
                 #:getter panel-hover-face)
  (hover-border  #:init-keyword #:hover-border  #:init-value #f
                 #:getter panel-hover-border)
  (content       #:init-keyword #:content       #:init-value #f
                 #:getter panel-content))

(define (panel? x)
  "Return #t if X is a <panel>."
  (is-a? x <panel>))

(define (panel . args)
  "Return a fresh <panel> initialised from ARGS, a sequence of
#:title, #:footer, #:border, #:face, #:hover-face, #:hover-border,
#:content keyword arguments."
  (apply make <panel> args))

(define-method (view (p <panel>))
  "Render <panel> P: P's content boxed with the configured
border, title, optional footer, and base face.  When a hover-face is
configured, wrap in `on-hover` so the frame face/border swap on
pointer hover."
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
