(define-module (canary widget)
  #:use-module (oop goops)
  #:use-module (ice-9 match)
  #:export (update-slots
            class-slot-keywords
            <canary-class>
            <component>
            define-component
            widget-id
            consumes-keys?))

;;; Commentary:
;;;
;;; (update-slots obj #:slot val ...) returns a fresh instance of the
;;; same kind as OBJ with every slot copied over except those listed
;;; in the override kwargs.  The slot list for each kind of node is
;;; looked up once and cached.
;;;
;;; <canary-class> is the metaclass for every component class.  It's
;;; currently a thin subclass of <class> with no overrides — its purpose
;;; is to give canary a hook point for future class-level behavior
;;; (custom redefinition semantics for live coding, slot-policy
;;; enforcement, per-class registry).  Subclasses of <component>
;;; inherit it automatically via `ensure-metaclass'.
;;;
;;; <component> is the instance-shape base class: every widget that the
;;; engine tracks (focus chain, mount/unmount, per-widget subs) inherits
;;; from it for the auto-generated identity slot.
;;;
;;; `define-component' is sugar for `(define-class NAME (<component>)
;;; SLOT ...)' — it injects <component> as the sole super so users don't
;;; spell the universal truth out per class.  Drop to plain `define-
;;; class' when you genuinely need multi-inheritance.
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

(define-class <canary-class> (<class>))

(define-class <component> ()
  (id #:init-form (gensym "w-") #:getter widget-id)
  #:metaclass <canary-class>)

(define-syntax-rule (define-component name slot/option ...)
  (define-class name (<component>) slot/option ...))

(define-method (consumes-keys? (w <component>))
  "Return #t when this focused component should swallow raw key events
before the engine consults its keymap.  Default #f.  Widgets that act
as text-entry surfaces (textinput, cmdlines, password fields) override
to #t so keymap-bound keys like Space or letters reach the field
instead of firing app-wide actions."
  #f)

(define (update-slots obj . overrides)
  "Return a fresh instance of the same kind as OBJ with every slot
copied from OBJ except those listed in OVERRIDES, a flat list of
#:slot value pairs.

Short-circuits to OBJ unchanged when every override value is
@code{equal?} to the slot it would replace — callers can then use
@code{(eq? old new)} as a reliable @q{did anything change?} signal
without forcing the entire cascade to allocate a fresh tree on every
heartbeat tick where nothing actually changed."
  (let* ((cls   (class-of obj))
         (pairs (class-slot-keywords cls)))
    (cond
     ((let loop ((rest overrides))
        (match rest
          (() #t)
          (((? keyword? kw) val . more)
           (let ((name (and=> (assq kw pairs) cdr)))
             (cond
              ((not name) #f)
              ((not (slot-bound? obj name)) #f)
              ((equal? val (slot-ref obj name)) (loop more))
              (else #f))))))
      obj)
     (else
      (let ((fresh   (make cls))
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
        fresh)))))
