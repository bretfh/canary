(define-module (gcell key)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<key> key key?
            key-sym key-mods key-event
            key=? key->string
            normalize-key))

(define-class <key> ()
  (sym   #:init-keyword #:sym   #:accessor key-sym)
  (mods  #:init-keyword #:mods  #:accessor key-mods)
  (event #:init-keyword #:event #:init-value 'press #:accessor key-event))

(define (canon-mod m)
  "Return the canonical symbol for modifier alias M.  Recognised
aliases: ctrl→control, option→alt, cmd/command→super.  `meta` and
`hyper` are their own modifiers (matches the kitty keyboard protocol)."
  (case m
    ((control ctrl)      'control)
    ((alt option)        'alt)
    ((shift)             'shift)
    ((super cmd command) 'super)
    ((meta)              'meta)
    ((hyper)             'hyper)
    (else (error "key: unknown modifier" m))))

(define (canon-mods mods)
  "Return MODS canonicalised: each entry mapped via canon-mod,
deduplicated, and sorted alphabetically so two equal modifier sets
compare equal."
  (sort (delete-duplicates (map canon-mod mods))
        (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))

(define (key? x)
  "Return #t if X is a <key>."
  (is-a? x <key>))

(define (key sym . mods)
  "Return a fresh <key> with symbol SYM and modifiers MODS.  MODS
are canonicalised; aliases (ctrl, option, cmd) accepted."
  (make <key> #:sym sym #:mods (canon-mods mods)))

(define (key=? a b)
  "Return #t if A and B are <key>s with equal symbol and modifier
set."
  (and (key? a) (key? b)
       (equal? (key-sym a) (key-sym b))
       (equal? (key-mods a) (key-mods b))))

(define (key->string k)
  "Return Emacs-style readable form of <key> K, e.g. \"C-a\",
\"C-S-tab\"."
  (let ((s (key-sym k)))
    (string-append
     (apply string-append
            (map (lambda (m)
                   (case m
                     ((control) "C-")
                     ((alt)     "A-")
                     ((shift)   "S-")
                     ((super)   "s-")
                     ((meta)    "M-")
                     ((hyper)   "H-")
                     (else (string-append (symbol->string m) "-"))))
                 (key-mods k)))
     (cond
      ((char? s)   (string s))
      ((symbol? s) (symbol->string s))
      (else        (format #f "~a" s))))))

(define (normalize-key x)
  "Coerce X into a <key>.  Accepted shapes: a <key> (returned as-is),
a char or symbol (treated as bare key), `(mouse BUTTON)` or
`(mouse-scroll DIR)`, or `(SYM MOD …)`.  Raises an error otherwise."
  (cond
   ((key? x)    x)
   ((char? x)   (make <key> #:sym x #:mods '()))
   ((symbol? x) (make <key> #:sym x #:mods '()))
   ((and (pair? x) (eq? (car x) 'mouse))
    (make <key> #:sym (cons 'mouse (cadr x)) #:mods '()))
   ((and (pair? x) (eq? (car x) 'mouse-scroll))
    (make <key> #:sym (cons 'mouse-scroll (cadr x)) #:mods '()))
   ((and (pair? x) (or (char? (car x)) (symbol? (car x))))
    (make <key> #:sym (car x) #:mods (canon-mods (cdr x))))
   (else (error "not a key" x))))
