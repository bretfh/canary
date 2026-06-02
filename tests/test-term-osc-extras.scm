(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             ((canary term types)  #:prefix t:)
             ((canary term parser) #:prefix t:))

(define (capture-osc opener key)
  (let ((box (list #f)))
    (let ((t (apply t:make-term
                    #:width 10 #:height 1
                    key (lambda (term data) (set-car! box data))
                    '())))
      (t:term-process-output! t opener)
      (car box))))

(test-begin "term-osc-extras")

(test-group "OSC 9 fires notification-fn with the body"
  (test-equal "OSC 9 body"
              "build failed"
              (capture-osc "\x1b]9;build failed\x1b\\" #:notification-fn)))

(test-group "OSC 777 fires notification-fn too"
  (test-equal "OSC 777 body"
              "notify;hello"
              (capture-osc "\x1b]777;notify;hello\x1b\\" #:notification-fn)))

(test-group "OSC 22 fires mouse-shape-fn with the cursor name"
  (test-equal "shape is 'pointer'"
              "pointer"
              (capture-osc "\x1b]22;pointer\x1b\\" #:mouse-shape-fn)))

(test-end "term-osc-extras")
