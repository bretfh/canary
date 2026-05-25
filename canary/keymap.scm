(define-module (canary keymap)
  #:use-module (canary key)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (<keymap>
            keymap keymap?
            bind
            <binding> binding?
            binding-keys binding-action binding-timeout-ms
            keymap-bindings
            keymap-pending
            keymap-step
            keymap-reset))

(define-record-type <binding>
  (binding keys timeout-ms action) binding?
  (keys       binding-keys)
  (timeout-ms binding-timeout-ms)
  (action     binding-action))

(define-record-type <keymap>
  (%keymap bindings pending) keymap?
  (bindings keymap-bindings)
  (pending  keymap-pending))

(define (bind . args)
  "Usage:
   (bind k1 [k2 ...] action)
   (bind k1 [k2 ...] action #:timeout-ms N)
Last positional value is the action. `#:timeout-ms` may trail."
  (let parse ((rev (reverse args)) (timeout #f))
    (cond
     ((and (pair? rev) (pair? (cdr rev)) (eq? (cadr rev) #:timeout-ms))
      (parse (cddr rev) (car rev)))
     ((null? rev) (error "bind: pass an action"))
     (else
      (let ((action  (car rev))
            (raw-keys (reverse (cdr rev))))
        (when (null? raw-keys)
          (error "bind: pass at least one key before the action"))
        (binding (map normalize-key raw-keys) timeout action))))))

(define (keymap . bindings)
  "Return a fresh <keymap> made of BINDINGS (each a <binding> from
`bind`), with an empty pending-key buffer."
  (%keymap bindings '()))

(define (keymap-reset km)
  "Return KM with its pending-key buffer cleared.  Leaves bindings
intact."
  (%keymap (keymap-bindings km) '()))

(define (key-list=? a b)
  "Return #t if key lists A and B are equal element-wise."
  (and (= (length a) (length b))
       (every key=? a b)))

(define (key-list-prefix? prefix candidate)
  "Return #t if PREFIX is a key-by-key prefix of CANDIDATE."
  (and (<= (length prefix) (length candidate))
       (key-list=? prefix (take candidate (length prefix)))))

(define (keymap-step km k)
  "Advance KM by feeding it key K.  Returns two values: the next
action (a value, or 'pending if still consuming a chord, or #f if K
was unbound) and the updated <keymap>."
  (let* ((pending  (append (keymap-pending km) (list (normalize-key k))))
         (bindings (keymap-bindings km))
         (exact    (find (lambda (b) (key-list=? pending (binding-keys b)))
                         bindings))
         (any-prefix?
          (any (lambda (b) (key-list-prefix? pending (binding-keys b)))
               bindings)))
    (cond
     (exact       (values (binding-action exact) (%keymap bindings '())))
     (any-prefix? (values 'pending                (%keymap bindings pending)))
     (else        (values #f                      (%keymap bindings '()))))))
