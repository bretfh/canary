(define-module (canary theme)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<theme>
            theme?
            theme
            theme-palettes
            theme-active
            theme-active-name
            theme-resolve
            theme-set!
            theme-cycle!
            palette
            <palette>
            palette?
            palette-name
            palette-entries
            default-theme))

(define-class <palette> ()
  (name    #:init-keyword #:name    #:accessor palette-name)
  (entries #:init-keyword #:entries #:accessor palette-entries))

(define (palette? x)
  "Return #t if X is a <palette>."
  (is-a? x <palette>))

(define-syntax palette
  (syntax-rules ()
    ((_ name (k v) ...)
     (make <palette>
       #:name 'name
       #:entries (list (cons 'k v) ...)))))

(define-class <theme> ()
  (palettes #:init-keyword #:palettes #:accessor theme-palettes)
  (active   #:init-value 0            #:accessor theme-active-idx))

(define (theme? x)
  "Return #t if X is a <theme>."
  (is-a? x <theme>))

(define (theme . palettes)
  "Return a fresh <theme> holding PALETTES, with the first palette
active.  At least one palette is required."
  (when (null? palettes)
    (error "theme: at least one palette required"))
  (make <theme> #:palettes palettes))

(define (theme-active th)
  "Return the currently active <palette> in <theme> TH."
  (list-ref (theme-palettes th) (theme-active-idx th)))

(define (theme-active-name th)
  "Return the name symbol of TH's currently active palette."
  (palette-name (theme-active th)))

(define (theme-resolve th name)
  "Look up NAME in the active palette. Returns hex string or #f."
  (cond
   ((not name) #f)
   ((string? name) name)
   ((symbol? name)
    (let ((hit (assq name (palette-entries (theme-active th)))))
      (and hit (cdr hit))))
   (else #f)))

(define (theme-set! th name)
  "Activate the palette named NAME. Returns #t on hit, #f if absent."
  (let lp ((ps (theme-palettes th)) (i 0))
    (cond
     ((null? ps) #f)
     ((eq? (palette-name (car ps)) name)
      (set! (theme-active-idx th) i)
      #t)
     (else (lp (cdr ps) (+ i 1))))))

(define (theme-cycle! th)
  "Advance to the next palette. Returns the new active palette's name."
  (let* ((n (length (theme-palettes th)))
         (next (modulo (+ (theme-active-idx th) 1) n)))
    (set! (theme-active-idx th) next)
    (theme-active-name th)))

(define default-theme
  (theme (palette dark
           (accent      "#ff6b9d")
           (dim         "#666666")
           (muted       "#888888")
           (hint        "#5a6378")
           (note        "#ff6b9d")
           (error       "#ff5555")
           (warning     "#f4c061")
           (info        "#7cd1e3")
           (success     "#00ff87")
           (heading     "#5599ff")
           (link        "#5599ff")
           (placeholder "#666666"))))
