(define-module (canary keymap)
  #:use-module (canary key)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (<keymap>
            keymap keymap?
            bind
            combo
            <binding> binding?
            binding-keys binding-action binding-timeout-ms
            <combo-binding> combo-binding?
            combo-keys combo-action
            keymap-bindings
            keymap-combos
            keymap-pending
            keymap-step
            keymap-match-combo
            keymap-combo-keys
            keymap-reset))

(define-record-type <binding>
  (binding keys timeout-ms action) binding?
  (keys       binding-keys)
  (timeout-ms binding-timeout-ms)
  (action     binding-action))

;; <combo-binding>: keys are a SET, not a sequence.  Fires when every
;; key in the set is held simultaneously at the moment one of them is
;; pressed.  The engine handles "held simultaneously" via the kitty
;; keyboard protocol (press+release events tracked into a held-set);
;; on terminals without kitty support the engine falls back to a brief
;; timeout window where any second press within window counts as held.
(define-record-type <combo-binding>
  (%combo-binding keys action) combo-binding?
  (keys   combo-keys)
  (action combo-action))

(define-record-type <keymap>
  (%keymap bindings combos pending) keymap?
  (bindings keymap-bindings)
  (combos   keymap-combos)
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

(define (combo keys action)
  "Return a fresh <combo-binding>: ACTION fires when every key in KEYS
is held simultaneously at the moment one of them is pressed.  KEYS is
a list of keys (chars, symbols, or `(SYM MOD …)` forms).  Order in
KEYS doesn't matter — match is by set membership."
  (%combo-binding (map normalize-key keys) action))

(define (keymap . items)
  "Return a fresh <keymap> from ITEMS, a mix of <binding>s (from
`bind`) and <combo-binding>s (from `combo`)."
  (let lp ((rest items) (bs '()) (cs '()))
    (cond
     ((null? rest)         (%keymap (reverse bs) (reverse cs) '()))
     ((binding? (car rest))
      (lp (cdr rest) (cons (car rest) bs) cs))
     ((combo-binding? (car rest))
      (lp (cdr rest) bs (cons (car rest) cs)))
     (else (error "keymap: not a binding or combo" (car rest))))))

(define (keymap-reset km)
  "Return KM with its pending-key buffer cleared.  Leaves bindings
and combos intact."
  (%keymap (keymap-bindings km) (keymap-combos km) '()))

(define (keymap-combo-keys km)
  "Return the union of all keys appearing in any combo of KM, as a
list of <key>s.  The engine uses this to know which keys it needs to
defer (a press of one of these may complete a combo)."
  (delete-duplicates
   (append-map combo-keys (keymap-combos km))
   key=?))

(define (subset-of-held? combo-keys held)
  "Return #t when every key in COMBO-KEYS is `key=?` to some key in
HELD."
  (every (lambda (k) (any (lambda (h) (key=? k h)) held))
         combo-keys))

(define (keymap-match-combo km held)
  "Return the combo-binding action whose key-set is EXACTLY the held
set (every held key appears in the combo and vice versa), or #f if
none match.  When multiple combos match, the one with the most keys
wins.  HELD is a list of <key>s."
  (let* ((same-size? (lambda (c) (= (length (combo-keys c)) (length held))))
         (matches (filter (lambda (c)
                            (and (same-size? c)
                                 (subset-of-held? (combo-keys c) held)
                                 (subset-of-held? held (combo-keys c))))
                          (keymap-combos km))))
    (cond
     ((null? matches) #f)
     (else (combo-action (car matches))))))

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
action (a value, or 'pending if still consuming a sequence binding,
or #f if K was unbound) and the updated <keymap>.  Only consults
sequence <binding>s; <combo-binding>s are matched separately by the
engine against the held-set via `keymap-match-combo`."
  (let* ((pending  (append (keymap-pending km) (list (normalize-key k))))
         (bindings (keymap-bindings km))
         (combos   (keymap-combos km))
         (exact    (find (lambda (b) (key-list=? pending (binding-keys b)))
                         bindings))
         (any-prefix?
          (any (lambda (b) (key-list-prefix? pending (binding-keys b)))
               bindings)))
    (cond
     (exact       (values (binding-action exact) (%keymap bindings combos '())))
     (any-prefix? (values 'pending                (%keymap bindings combos pending)))
     (else        (values #f                      (%keymap bindings combos '()))))))
