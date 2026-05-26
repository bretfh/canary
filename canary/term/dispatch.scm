(define-module (canary term dispatch)
  #:use-module (oop goops)
  #:use-module (canary view)
  #:use-module (canary term types)
  #:use-module (canary term ops)
  #:use-module (canary term action)
  #:use-module (canary term modes)
  #:export (<op>
            op?

            <op-set-mode>
            op-set-mode
            op-mode-set-mode?

            <op-reset-mode>
            op-reset-mode
            op-mode-reset-mode?

            op-mode-number
            op-mode-private?

            dispatch-action!))

;;; Commentary:
;;;
;;; Semantic op records and the action -> op translator.
;;;
;;; The parser produces raw <action> records (in (canary term action));
;;; this module turns them into typed semantic <op-*> records and
;;; delivers each op to a <term> through canary's existing `update`
;;; generic.  The contract on every method is `(values term cmd-or-#f)`,
;;; the same shape that drives canary widgets.
;;;
;;; To intercept any emulator decision, specialise update at the REPL:
;;;
;;;   (define-method (update t (op <op-set-mode>))
;;;     (engine-log! "mode ~a := ~a" (op-mode-number op) #t)
;;;     (next-method))
;;;
;;; The base <op> class lets a single method capture every op kind via
;;;   (define-method (update t (op <op>)) ...).
;;;
;;; Code:

(define-class <op> ())

(define (op? x)
  "Return #t if X is an instance of any <op> subclass."
  (is-a? x <op>))

(define-class <op-set-mode> (<op>)
  (number   #:init-keyword #:number   #:accessor op-mode-number)
  (private? #:init-keyword #:private? #:accessor op-mode-private?))

(define-class <op-reset-mode> (<op>)
  (number   #:init-keyword #:number   #:accessor op-mode-number)
  (private? #:init-keyword #:private? #:accessor op-mode-private?))

(define (op-set-mode number private?)
  "Return a fresh <op-set-mode> for mode NUMBER.  PRIVATE? is #t for
DEC private modes (CSI ? Pm h), #f for ANSI modes (CSI Pm h)."
  (make <op-set-mode> #:number number #:private? private?))

(define (op-reset-mode number private?)
  "Return a fresh <op-reset-mode> for mode NUMBER.  PRIVATE? is #t for
DEC private modes (CSI ? Pm l), #f for ANSI modes (CSI Pm l)."
  (make <op-reset-mode> #:number number #:private? private?))

(define (op-mode-set-mode? x)
  "Return #t if X is an <op-set-mode>."
  (is-a? x <op-set-mode>))

(define (op-mode-reset-mode? x)
  "Return #t if X is an <op-reset-mode>."
  (is-a? x <op-reset-mode>))


;;;
;;; Side effects on <term> for the mode ops.
;;;

(define (mode-side-effect! term number private? value)
  "Trigger side effects for modes whose semantics go beyond a flag:
alt-screen composite modes, cursor-blink mapping into cursor-style,
etc.  Returns #t if NUMBER had a side effect (and the flag has
already been applied), #f if the caller still needs to set the flag."
  (cond
   ((not private?) #f)
   (else
    (case number
      ((12)
       (cond
        (value
         (case (term-cursor-style term)
           ((block)     (set-term-cursor-style! term 'blinking-block))
           ((underline) (set-term-cursor-style! term 'blinking-underline))
           ((bar)       (set-term-cursor-style! term 'blinking-bar))))
        (else
         (case (term-cursor-style term)
           ((blinking-block)     (set-term-cursor-style! term 'block))
           ((blinking-underline) (set-term-cursor-style! term 'underline))
           ((blinking-bar)       (set-term-cursor-style! term 'bar)))))
       #f)
      ((1047) (if value
                  (term-enter-alt-screen! term)
                  (term-exit-alt-screen! term))
              #f)
      ((1048) (if value
                  (term-save-cursor! term)
                  (term-restore-cursor! term))
              #f)
      ((1049) (cond
               (value (term-save-cursor! term)
                      (term-enter-alt-screen! term))
               (else  (term-exit-alt-screen! term)
                      (term-restore-cursor! term)))
              #f)
      (else #f)))))

(define (apply-mode! term number private? value)
  "Update TERM's mode flag for (PRIVATE?, NUMBER) to VALUE and trigger
any associated side effect (alt-screen swap, cursor blink, etc.)."
  (mode-side-effect! term number private? value)
  (let ((def (mode-def-by-key (if private? 'dec-private 'ansi) number)))
    (when def
      (mode-set! (term-modes term) (mode-def-name def) value))))

(define-method (update term (op <op-set-mode>))
  "Set the mode named by OP on TERM.  Returns (values TERM #f)."
  (apply-mode! term (op-mode-number op) (op-mode-private? op) #t)
  (values term #f))

(define-method (update term (op <op-reset-mode>))
  "Reset the mode named by OP on TERM.  Returns (values TERM #f)."
  (apply-mode! term (op-mode-number op) (op-mode-private? op) #f)
  (values term #f))


;;;
;;; Action -> op translation.
;;;

(define (csi->mode-ops action set?)
  "Return the list of <op-set-mode> (when SET? is #t) or <op-reset-mode>
(when SET? is #f) records implied by the CSI ACTION's params and
private-format byte.  CSI h / l can carry multiple mode numbers in one
sequence; emit one op per number."
  (let ((private? (eqv? (action-csi-fmt action) #\?))
        (make-op (if set? op-set-mode op-reset-mode)))
    (let loop ((ps (action-csi-params action))
               (acc '()))
      (cond
       ((null? ps) (reverse acc))
       (else
        (let ((p (car ps)))
          (loop (cdr ps)
                (if p (cons (make-op p private?) acc) acc))))))))

(define (dispatch-action! term action)
  "Translate ACTION (a <action-csi> for now) into one or more op
records and deliver each to TERM through the `update` generic.
Returns unspecified."
  (let ((final (and (is-a? action <action-csi>) (action-csi-final action))))
    (when final
      (let ((fmt (action-csi-fmt action)))
        (cond
         ;; CSI h: set mode(s).  ANSI when fmt is #f; DEC-private when '?'.
         ((and (char=? final #\h)
               (or (not fmt) (char=? fmt #\?)))
          (for-each (lambda (op) (update term op))
                    (csi->mode-ops action #t)))
         ;; CSI l: reset mode(s).
         ((and (char=? final #\l)
               (or (not fmt) (char=? fmt #\?)))
          (for-each (lambda (op) (update term op))
                    (csi->mode-ops action #f))))))))
