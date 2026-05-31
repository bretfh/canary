(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (gcell key)
             (gcell keymap))

(test-begin "keymap")

(define km
  (keymap (bind #\q 'quit)
          (bind '(#\x ctrl) '(#\c ctrl) 'force-quit)))

(test-equal "single key match"
            'quit
            (call-with-values (lambda () (keymap-step km #\q))
                              (lambda (r _) r)))

(test-equal "non-match returns #f"
            #f
            (call-with-values (lambda () (keymap-step km #\z))
                              (lambda (r _) r)))

(test-equal "key prefix returns pending"
            'pending
            (call-with-values (lambda () (keymap-step km (key #\x 'control)))
                              (lambda (r _) r)))

(test-equal "second key of sequence completes binding"
            'force-quit
            (call-with-values
                (lambda ()
                  (call-with-values
                      (lambda () (keymap-step km (key #\x 'control)))
                    (lambda (_ km2)
                      (keymap-step km2 (key #\c 'control)))))
              (lambda (r _) r)))

(test-end "keymap")
