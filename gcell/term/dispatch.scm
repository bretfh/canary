(define-module (gcell term dispatch)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (gcell view)
  #:use-module (gcell term types)
  #:use-module (gcell term ops)
  #:use-module (gcell term action)
  #:use-module (gcell term modes)
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
;;; The parser produces raw <action> records (in (gcell term action));
;;; this module turns them into typed semantic <op-*> records and
;;; delivers each op to a <term> through gcell's existing `update`
;;; generic.  Each method mutates the term in place and returns a
;;; cmd-or-#f, the same shape that drives gcell widgets.
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

(define (cursor-style-blink-on style)
  (case style
    ((block)     'blinking-block)
    ((underline) 'blinking-underline)
    ((bar)       'blinking-bar)
    (else        style)))

(define (cursor-style-blink-off style)
  (case style
    ((blinking-block)     'block)
    ((blinking-underline) 'underline)
    ((blinking-bar)       'bar)
    (else                 style)))

(define (mode-side-effect! term number private? value)
  "Trigger side effects for modes whose semantics go beyond a flag:
alt-screen composite modes, cursor-blink mapping into cursor-style.
A no-op for everything else."
  (and private?
       (case number
         ((12)
          (set-term-cursor-style! term
                                  ((if value
                                       cursor-style-blink-on
                                       cursor-style-blink-off)
                                   (term-cursor-style term))))
         ((1047)
          ((if value term-enter-alt-screen! term-exit-alt-screen!) term))
         ((1048)
          ((if value term-save-cursor! term-restore-cursor!) term))
         ((1049)
          (cond
           (value (term-save-cursor! term)
                  (term-enter-alt-screen! term))
           (else  (term-exit-alt-screen! term)
                  (term-restore-cursor! term))))
         (else #f))))

(define (apply-mode! term number private? value)
  "Update TERM's mode flag for (PRIVATE?, NUMBER) to VALUE and trigger
any associated side effect (alt-screen swap, cursor blink, etc.)."
  (mode-side-effect! term number private? value)
  (and=> (mode-def-by-key (if private? 'dec-private 'ansi) number)
         (lambda (def)
           (mode-set! (term-modes term) (mode-def-name def) value))))

(define-method (update term (op <op-set-mode>))
  "Set the mode named by OP on TERM."
  (apply-mode! term (op-mode-number op) (op-mode-private? op) #t)
  #f)

(define-method (update term (op <op-reset-mode>))
  "Reset the mode named by OP on TERM."
  (apply-mode! term (op-mode-number op) (op-mode-private? op) #f)
  #f)


;;;
;;; Action -> op translation.
;;;

(define (csi->mode-ops action set?)
  "Return the <op-set-mode> (when SET? is #t) or <op-reset-mode>
records implied by the CSI ACTION's params and private-format byte.
CSI h / l can carry multiple mode numbers in one sequence; emit one
op per number, dropping #f entries from the parser's param list."
  (let ((private? (eqv? (action-csi-fmt action) #\?))
        (make-op (if set? op-set-mode op-reset-mode)))
    (filter-map (lambda (p) (and p (make-op p private?)))
                (action-csi-params action))))

(define (mode-final? fmt final)
  (and (memv final '(#\h #\l))
       (or (not fmt) (char=? fmt #\?))))

(define (dispatch-action! term action)
  "Translate ACTION into one or more op records and deliver each to
TERM through the `update` generic.  Returns unspecified."
  (and (is-a? action <action-csi>)
       (let ((final (action-csi-final action))
             (fmt   (action-csi-fmt action)))
         (when (mode-final? fmt final)
           (for-each (lambda (op) (update term op))
                     (csi->mode-ops action (char=? final #\h)))))))
