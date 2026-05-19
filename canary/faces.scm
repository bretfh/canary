(define-module (canary faces)
  #:use-module (srfi srfi-9)
  #:export (<face>
            face face?
            face-fg face-bg face-attrs
            default-faces
            face-table-lookup
            extend-face-table
            faces))

(define-record-type <face>
  (%face fg bg attrs) face?
  (fg    face-fg)
  (bg    face-bg)
  (attrs face-attrs))

(define* (face #:key fg bg (attrs '()))
  (%face fg bg attrs))

(define default-faces
  `((default     . ,(face))
    (accent      . ,(face #:fg "#ff6b9d" #:attrs '(bold)))
    (dim         . ,(face #:fg "#666666"))
    (muted       . ,(face #:fg "#888888"))
    (error       . ,(face #:fg "#ff5555" #:attrs '(bold)))
    (warning     . ,(face #:fg "#f4c061"))
    (info        . ,(face #:fg "#7cd1e3"))
    (success     . ,(face #:fg "#00ff87"))
    (heading     . ,(face #:fg "#5599ff" #:attrs '(bold)))
    (link        . ,(face #:fg "#5599ff" #:attrs '(underline)))
    (selection   . ,(face #:fg "#ffffff" #:bg "#322a44"))
    (cursor      . ,(face #:fg "#000000" #:bg "#ffffff"))
    (placeholder . ,(face #:fg "#666666" #:attrs '(italic)))))

(define (face-table-lookup table name)
  (cond
   ((face? name) name)
   ((not name)   (face-table-lookup table 'default))
   ((assq name table) => cdr)
   (else (face-table-lookup table 'default))))

(define (extend-face-table base overrides)
  (append overrides base))

(define-syntax-rule (faces (name expr) ...)
  (list (cons 'name expr) ...))
