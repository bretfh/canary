(define-module (canary node)
  #:use-module (canary view)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-17)
  #:export (define-node))

;; define-node — the author-facing way to make a stateful, reusable
;; node. Expansion:
;;
;;   (define-node counter
;;     #:state ((n 0))
;;     #:view  (lambda (self) (txt (number->string (counter-n self))))
;;     #:react (lambda (self msg) ...)
;;     #:init  (lambda (self) ...))         ; optional
;;
;; expands to:
;;
;;   - a hidden state record (slot accessors invisible to user)
;;   - public per-slot accessors  counter-n / set-counter-n!
;;   - public predicate           counter?
;;   - public constructor         (make-counter [#:n 0] ...)  → <stateful>
;;
;; #:state ((slot-name init-value) ...) — required (use #:state ()
;; for nodes with no state).
;; #:view  — required; receives the <stateful> wrapper, returns a node.
;; #:react — optional; receives wrapper + msg. Mutate state via the
;;           generated setters; return #f or a cmd (see canary/cmd).
;; #:init  — optional; receives wrapper, called once before first render.
;;           Mutate state in place; return value is discarded.
;;
;; Accessors take the <stateful> wrapper, not the inner state record —
;; authors never touch the inner record. (counter-n self) reads;
;; (set-counter-n! self v) writes. The wrapper is what gets passed
;; around in trees and what the engine walks.

(define-syntax define-node
  (lambda (stx)
    (define (sym . parts)
      (string->symbol
       (apply string-append
              (map (lambda (p)
                     (cond ((symbol? p) (symbol->string p))
                           ((string? p) p)
                           (else (error "sym: bad part" p))))
                   parts))))
    (define (id ctx . parts)
      (datum->syntax ctx (apply sym parts)))
    (syntax-case stx ()
      ((_ name kw* ...)
       (let* ((name-sym (syntax->datum #'name))
              (kws      (syntax->datum #'(kw* ...)))
              (state    (let lp ((rest kws))
                          (cond
                           ((null? rest) (error "define-node: missing #:state" name-sym))
                           ((eq? (car rest) #:state) (cadr rest))
                           (else (lp (cddr rest))))))
              (view-expr (let lp ((rest kws))
                           (cond
                            ((null? rest) (error "define-node: missing #:view" name-sym))
                            ((eq? (car rest) #:view) (cadr rest))
                            (else (lp (cddr rest))))))
              (react-expr (let lp ((rest kws))
                            (cond
                             ((null? rest) #f)
                             ((eq? (car rest) #:react) (cadr rest))
                             (else (lp (cddr rest))))))
              (init-expr  (let lp ((rest kws))
                            (cond
                             ((null? rest) #f)
                             ((eq? (car rest) #:init) (cadr rest))
                             (else (lp (cddr rest))))))
              (slots      (map car state))
              (inits      (map cadr state)))
         (with-syntax
             ((rec-type     (id #'name "<" name-sym "-state>"))
              (rec-pred     (id #'name name-sym "-state?"))
              (rec-make     (id #'name "%make-" name-sym "-state"))
              (make-name    (id #'name "make-" name-sym))
              (pred-name    (id #'name name-sym "?"))
              ((slot ...)        (map (lambda (s) (datum->syntax #'name s)) slots))
              ((init ...)        (map (lambda (v) (datum->syntax #'name v)) inits))
              ((priv-acc ...)    (map (lambda (s) (id #'name "%" name-sym "-" s)) slots))
              ((priv-set ...)    (map (lambda (s) (id #'name "%set-" name-sym "-" s "!")) slots))
              ((pub-acc ...)     (map (lambda (s) (id #'name name-sym "-" s)) slots))
              ((pub-set ...)     (map (lambda (s) (id #'name "set-" name-sym "-" s "!")) slots))
              (view-form    (datum->syntax #'name view-expr))
              (react-form   (datum->syntax #'name react-expr))
              (init-form    (datum->syntax #'name init-expr)))
           #'(begin
               (define-record-type rec-type
                 (rec-make slot ...)
                 rec-pred
                 (slot priv-acc priv-set) ...)
               ;; Explicit setter procs — useful when callers prefer
               ;; named mutation over generalized-variable form.
               (define (pub-set self v) (priv-set (stateful-state self) v))
               ...
               ;; Generalized-variable accessor: works as `(pub-acc self)`
               ;; (read) AND `(set! (pub-acc self) v)` (write).
               (define pub-acc
                 (getter-with-setter
                  (lambda (self) (priv-acc (stateful-state self)))
                  (lambda (self v) (priv-set (stateful-state self) v))))
               ...
               (define (pred-name x)
                 (and (stateful? x) (rec-pred (stateful-state x))))
               (define* (make-name #:key (slot init) ...)
                 (make-stateful (rec-make slot ...)
                                view-form
                                #:react-proc react-form
                                #:init-proc  init-form)))))))))
