(define-module (canary keymap-input)
  #:use-module (canary key)
  #:use-module (canary keymap)
  #:use-module (canary protocol)
  #:export (feed-key
            feed-key-stack
            mouse->key))

(define (mouse->key msg)
  "Translate a <mouse> event MSG into the equivalent synthetic <key>
for keymap matching, or #f if the action isn't bindable.  Press and
click both produce `(mouse left|middle|right)`; scroll-up and
scroll-down produce `(mouse-scroll up|down)`."
  (let ((a (mouse-action msg))
        (b (mouse-button msg)))
    (case a
      ((press click)
       (case b
         ((0) (key (cons 'mouse 'left)))
         ((1) (key (cons 'mouse 'middle)))
         ((2) (key (cons 'mouse 'right)))
         (else #f)))
      ((scroll-up)   (key (cons 'mouse-scroll 'up)))
      ((scroll-down) (key (cons 'mouse-scroll 'down)))
      (else #f))))

(define (feed-key km msg)
  "Advance keymap KM by an input MSG (either a <key> or a <mouse>),
returning two values: the matched action (or 'pending, or #f) and
the updated keymap.  Non-input msgs pass through with no advance."
  (cond
   ((key? msg)   (keymap-step km msg))
   ((mouse? msg) (let ((k (mouse->key msg)))
                   (if k (keymap-step km k) (values #f km))))
   (else (values #f km))))

(define (feed-key-stack kms msg)
  "Feed MSG into KMS, a list of <keymap>s in priority order (highest
first).  Walk top-down; on the first non-#f result, return.  Each
keymap visited is stepped and the returned list mirrors KMS with each
visited keymap replaced by its stepped copy.

Returns two values: ACTION (a value, or 'pending if some keymap is
chord-waiting, or #f if none matched) and the new list of keymaps."
  (let loop ((rest kms) (visited '()))
    (cond
     ((null? rest)
      (values #f (reverse visited)))
     (else
      (let* ((km (car rest)))
        (call-with-values (lambda () (feed-key km msg))
          (lambda (action new-km)
            (cond
             ((or (eq? action 'pending) action)
              (values action (append (reverse visited)
                                     (cons new-km (cdr rest)))))
             (else
              (loop (cdr rest) (cons new-km visited)))))))))))
