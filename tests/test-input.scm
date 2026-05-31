(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (gcell input)
             (gcell protocol)
             (gcell key))

(test-begin "input")

(define (parse-bytes str)
  "Feed STR through read-key-msg as if it arrived on stdin."
  (with-input-from-string str read-key-msg))

(test-assert "plain char"
             (key=? (key #\a) (parse-bytes "a")))

(test-assert "ctrl-a (raw 0x01)"
             (key=? (key #\a 'control) (parse-bytes "\x01")))

(test-assert "csi arrow up"
             (key=? (key 'up) (parse-bytes "\x1b[A")))

(test-assert "csi shift+arrow uses xterm mod"
             (key=? (key 'up 'shift) (parse-bytes "\x1b[1;2A")))

(test-equal "bracketed paste captures payload"
            "hello world"
            (let ((msg (parse-bytes "\x1b[200~hello world\x1b[201~")))
              (and (paste? msg) (paste-text msg))))

(test-equal "bracketed paste survives newlines + control bytes"
            "a\nb\tc"
            (let ((msg (parse-bytes "\x1b[200~a\nb\tc\x1b[201~")))
              (and (paste? msg) (paste-text msg))))

(test-assert "kitty csi-u plain a"
             (key=? (key #\a) (parse-bytes "\x1b[97u")))

(test-assert "kitty csi-u ctrl+i is not tab"
             (let ((k (parse-bytes "\x1b[105;5u")))
               (and (key? k)
                    (equal? (key-sym k) #\i)
                    (equal? (key-mods k) '(control)))))

(test-assert "kitty csi-u tab"
             (key=? (key 'tab) (parse-bytes "\x1b[9u")))

(test-assert "kitty csi-u escape"
             (key=? (key 'escape) (parse-bytes "\x1b[27u")))

(test-assert "kitty csi-u shift+ctrl+x"
             (let ((k (parse-bytes "\x1b[120;6u")))
               (and (key? k)
                    (equal? (key-sym k) #\x)
                    (equal? (key-mods k) '(control shift)))))

(test-assert "kitty csi-u functional left arrow"
             (key=? (key 'left) (parse-bytes "\x1b[57350u")))

(test-assert "kitty csi-u f3"
             (key=? (key 'f3) (parse-bytes "\x1b[57366u")))

(test-assert "kitty meta is its own modifier"
             (let ((k (parse-bytes "\x1b[97;33u")))   ; mod=33 → 32 bit set = meta
               (and (key? k)
                    (equal? (key-mods k) '(meta)))))

(test-assert "kitty hyper distinct from super"
             (let ((k (parse-bytes "\x1b[97;17u")))   ; mod=17 → 16 bit set = hyper
               (and (key? k)
                    (equal? (key-mods k) '(hyper)))))

(test-end "input")
