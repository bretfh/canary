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
  "Return a fresh <face>.  FG and BG are color strings (e.g. \"#ff00aa\")
or #f.  ATTRS is a list of attribute symbols like 'bold, 'italic,
'underline."
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
  "Resolve NAME against TABLE, an alist of face names to <face>s.
NAME may be a symbol (looked up in TABLE), a literal <face> (returned
as-is), or #f (treated as 'default).  Falls back to the 'default
entry when NAME is unknown."
  (cond
   ((face? name) name)
   ((not name)   (face-table-lookup table 'default))
   ((assq name table) => cdr)
   (else (face-table-lookup table 'default))))

(define (extend-face-table base overrides)
  "Return a face table that prepends OVERRIDES to BASE.  Earlier
entries shadow later ones, so OVERRIDES win on duplicate keys."
  (append overrides base))

(define-syntax-rule (faces (name expr) ...)
  (list (cons 'name expr) ...))
