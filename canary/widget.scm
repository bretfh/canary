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

(define-class <focusable> ()
  (id #:init-form (gensym "w-") #:getter widget-id))

(define (update-slots obj . overrides)
  "Return a fresh instance of the same kind as OBJ with every slot
copied from OBJ except those listed in OVERRIDES, a flat list of
#:slot value pairs.  Slot values are copied via slot-set! so the
helper works regardless of whether a slot declares an #:init-keyword.
Unknown override keywords raise an error."
  (let* ((cls     (class-of obj))
         (pairs   (class-slot-keywords cls))
         (fresh   (make cls))
         (touched (make-hash-table)))
    (let loop ((rest overrides))
      (match rest
        (() #t)
        (((? keyword? kw) val . more)
         (let ((name (and=> (assq kw pairs) cdr)))
           (cond
            ((not name) (error "update-slots: unknown slot" kw))
            (else
             (slot-set! fresh name val)
             (hashq-set! touched name #t)
             (loop more)))))))
    (for-each (lambda (kv)
                (let ((name (cdr kv)))
                  (unless (hashq-ref touched name)
                    (when (slot-bound? obj name)
                      (slot-set! fresh name (slot-ref obj name))))))
              pairs)
    fresh))
