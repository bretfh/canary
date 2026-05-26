(define-module (canary widget)
  #:use-module (oop goops)
  #:use-module (ice-9 match)
  #:export (update-slots
            <focusable>
            widget-id))

;;; Commentary:
;;;
;;; (update-slots obj #:slot val ...) returns a fresh instance of the
;;; same kind as OBJ with every slot copied over except those listed
;;; in the override kwargs.  The slot list for each kind of node is
;;; looked up once and cached.
;;;
;;; Code:

(define %slot-keyword-cache (make-hash-table))

(define (class-slot-keywords cls)
  "Return CLS's slot list as a cached list of (#:keyword . name)
pairs.  The lookup runs once per class; subsequent calls hit the
cache."
  (or (hash-ref %slot-keyword-cache cls)
      (let ((pairs (map (lambda (slot)
                          (let ((name (slot-definition-name slot)))
                            (cons (symbol->keyword name) name)))
                        (class-slots cls))))
        (hash-set! %slot-keyword-cache cls pairs)
        pairs)))

(define (override-keywords overrides)
  "Return the set of keywords present in the flat OVERRIDES list as a
list of keyword symbols.  Used to skip those slots when building the
base initargs so overrides win."
  (let loop ((rest overrides) (acc '()))
    (match rest
      (()                 acc)
      ((_)                acc)
      ((kw _ . more)      (loop more (cons kw acc))))))

(define-class <focusable> ()
  (id #:init-form (gensym "w-") #:getter widget-id))

(define (update-slots obj . overrides)
  "Return a fresh instance of the same kind as OBJ with every slot
copied from OBJ except those listed in OVERRIDES, a flat list of
#:slot value pairs.  Unknown keywords raise an error."
  (let* ((cls         (class-of obj))
         (pairs       (class-slot-keywords cls))
         (overridden? (let ((kws (override-keywords overrides)))
                        (lambda (kw) (memq kw kws))))
         (base        (let loop ((rest pairs) (acc '()))
                        (match rest
                          (() (reverse acc))
                          (((kw . name) . more)
                           (cond
                            ((overridden? kw) (loop more acc))
                            (else
                             (loop more
                                   (cons* (slot-ref obj name)
                                          kw
                                          acc)))))))))
    (apply make cls (append base overrides))))
