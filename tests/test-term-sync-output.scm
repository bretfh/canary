(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             ((gcell term types)  #:prefix t:)
             ((gcell term parser) #:prefix t:)
             ((gcell term modes)  #:prefix t:))

(define (sync-on? t) (t:mode-get (t:term-modes t) 'sync-output))

(test-begin "term-sync-output")

(test-group "CSI ?2026 h/l toggles the sync-output mode"
  (let ((t (t:make-term #:width 10 #:height 1)))
    (test-assert "default is off" (not (sync-on? t)))
    (t:term-process-output! t "\x1b[?2026h")
    (test-assert "after CSI ?2026 h it's on" (sync-on? t))
    (t:term-process-output! t "\x1b[?2026l")
    (test-assert "after CSI ?2026 l it's off" (not (sync-on? t)))))

(test-group "a sync-bracketed update parses into one final state"
  (let ((t (t:make-term #:width 10 #:height 1)))
    (t:term-process-output! t
      (string-append
       "\x1b[?2026h"
       "abc"
       "\x1b[1;1H"
       "xyz"
       "\x1b[?2026l"))
    (test-assert "sync was disabled at the end"
                 (not (sync-on? t)))))

(test-end "term-sync-output")
