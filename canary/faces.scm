(define-module (canary faces)
  #:use-module (srfi srfi-9)
  #:export (<face>
            face face?
            face-fg face-bg face-attrs face-hyperlink face-semantic
            with-hyperlink with-semantic
            default-faces
            face-table-lookup
            extend-face-table
            faces))

(define-record-type <face>
  (%face fg bg attrs hyperlink semantic) face?
  (fg        face-fg)
  (bg        face-bg)
  (attrs     face-attrs)
  (hyperlink face-hyperlink)
  (semantic  face-semantic))

(define* (face #:key fg bg (attrs '()) (hyperlink #f) (semantic #f))
  "Return a fresh <face>.  FG and BG are colour strings (e.g.
\"#ff00aa\") or #f.  ATTRS is a list of attribute symbols like
'bold, 'italic, 'underline.  HYPERLINK is a uri string (the cells
this face decorates render as a clickable OSC 8 link in capable
host terminals) or #f.  SEMANTIC is one of 'prompt / 'input /
'output / 'unknown, tagging the cells for OSC 133 shell-integration
consumers."
  (%face fg bg attrs hyperlink semantic))

(define (with-hyperlink f uri)
  "Return a copy of <face> F with its hyperlink slot set to URI.
F may also be #f, in which case a fresh default <face> is returned
carrying just the hyperlink."
  (cond
   ((face? f) (%face (face-fg f) (face-bg f) (face-attrs f) uri (face-semantic f)))
   (else (%face #f #f '() uri #f))))

(define (with-semantic f kind)
  "Return a copy of <face> F with its semantic slot set to KIND
(one of 'prompt / 'input / 'output / 'unknown / #f).  F may also be
#f, in which case a fresh default <face> is returned carrying just
the semantic tag."
  (cond
   ((face? f) (%face (face-fg f) (face-bg f) (face-attrs f) (face-hyperlink f) kind))
   (else (%face #f #f '() #f kind))))

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
