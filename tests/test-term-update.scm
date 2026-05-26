(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (oop goops)
             (canary view)
             ((canary term types)    #:prefix t:)
             ((canary term parser)   #:prefix t:)
             ((canary term dispatch) #:prefix t:))

(define (fresh)
  (t:make-term #:width 10 #:height 3))

(test-begin "term-update")

(test-group "parser delivers <op-set-mode> through the update generic"
  (let ((t (fresh)))
    (t:term-process-output! t "\x1b[?25l")
    (test-assert "cursor-visible? cleared after CSI ?25 l"
                 (not (t:term-cursor-visible? t)))
    (t:term-process-output! t "\x1b[?25h")
    (test-assert "cursor-visible? set again after CSI ?25 h"
                 (t:term-cursor-visible? t))))

(test-group "ANSI mode 4 (insert mode) routes through the same path"
  (let ((t (fresh)))
    (t:term-process-output! t "\x1b[4h")
    (test-assert "insert? set"      (t:term-insert? t))
    (t:term-process-output! t "\x1b[4l")
    (test-assert "insert? cleared"  (not (t:term-insert? t)))))

(test-group "update can be called directly with an op record"
  (let ((t (fresh)))
    (call-with-values
     (lambda () (update t (t:op-set-mode 25 #t)))
     (lambda (returned-term cmd)
       (test-eq "returns the same term" t returned-term)
       (test-assert "no cmd produced for plain mode set"
                    (not cmd))
       (test-assert "cursor-visible? is now set"
                    (t:term-cursor-visible? t))))))

(test-group "op records preserve mode number and private? for inspection"
  (let ((op (t:op-set-mode 1049 #t)))
    (test-equal "number"   1049 (t:op-mode-number op))
    (test-assert "private?"      (t:op-mode-private? op))
    (test-assert "is set-mode?"  (t:op-mode-set-mode? op))
    (test-assert "not reset?"    (not (t:op-mode-reset-mode? op)))))

(test-group "multi-param CSI h splits into one op per number"
  (let ((t (fresh)))
    (t:set-term-cursor-visible! t #f)
    (t:set-term-bracketed-paste! t #f)
    (t:term-process-output! t "\x1b[?25;2004h")
    (test-assert "cursor-visible? set"  (t:term-cursor-visible? t))
    (test-assert "bracketed-paste? set" (t:term-bracketed-paste? t))))

(test-end "term-update")
