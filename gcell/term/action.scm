(define-module (gcell term action)
  #:use-module (oop goops)
  #:export (<action>
            action?
            <action-csi>
            action-csi
            action-csi-fmt
            action-csi-params
            action-csi-intermediates
            action-csi-final))

;;; Commentary:
;;;
;;; Parser-output records.  The parser in (gcell term parser)
;;; decomposes its input byte stream into a sequence of <action>
;;; instances; these are the raw, syntactic form of each control
;;; sequence.  Semantic interpretation -- "this CSI h means set mode
;;; X" -- happens in (gcell term dispatch) on top of these records.
;;;
;;; Keeping the parser's output explicit lets external code observe
;;; what the byte stream is asking for before any side effect lands
;;; on a <term>: loggers, recorders, fuzzers.
;;;
;;; Code:

(define-class <action> ())

(define (action? x)
  "Return #t if X is an instance of any <action> subclass."
  (is-a? x <action>))

(define-class <action-csi> (<action>)
  (fmt           #:init-keyword #:fmt           #:accessor action-csi-fmt)
  (params        #:init-keyword #:params        #:accessor action-csi-params)
  (intermediates #:init-keyword #:intermediates #:accessor action-csi-intermediates
                                                #:init-value '())
  (final         #:init-keyword #:final         #:accessor action-csi-final))

(define* (action-csi #:key fmt params (intermediates '()) final)
  "Return a fresh <action-csi> capturing a parsed CSI sequence.  FMT is
the private-format byte (#\\? / #\\> / #\\= / #f).  PARAMS is the
decoded parameter list as emitted by the parser (with colon
sub-parameters promoted to sublists).  INTERMEDIATES is the list of
intermediate bytes (0x20-0x2F) seen after parameters.  FINAL is the
final byte (a char in @../~) that completes the CSI."
  (make <action-csi> #:fmt fmt #:params params
        #:intermediates intermediates #:final final))
