(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (gcell key))

(test-begin "key")

(test-assert "char keys equal"
             (key=? (key #\a) (key #\a)))
(test-assert "different chars not equal"
             (not (key=? (key #\a) (key #\b))))
(test-assert "mods order ignored"
             (key=? (key #\a 'control 'alt)
                    (key #\a 'alt 'control)))
(test-assert "duplicate mods deduped"
             (key=? (key #\a 'control)
                    (key #\a 'control 'control)))
(test-assert "ctrl alias for control"
             (key=? (key #\a 'ctrl)
                    (key #\a 'control)))
(test-assert "alt and meta are distinct"
             (not (key=? (key #\a 'alt)
                         (key #\a 'meta))))
(test-assert "option is alt alias"
             (key=? (key #\a 'alt)
                    (key #\a 'option)))
(test-assert "hyper is its own mod"
             (key=? (key #\a 'hyper)
                    (key #\a 'hyper)))
(test-equal "string form with control" "C-x"   (key->string (key #\x 'control)))
(test-equal "string form ctrl+alt"     "A-C-x" (key->string (key #\x 'alt 'control)))
(test-equal "string form symbol key"   "A-tab" (key->string (key 'tab 'alt)))

(test-assert "normalize char"
             (key=? (key #\h)            (normalize-key #\h)))
(test-assert "normalize symbol"
             (key=? (key 'left)          (normalize-key 'left)))
(test-assert "normalize list"
             (key=? (key #\x 'control)   (normalize-key '(#\x control))))
(test-assert "normalize list with ctrl alias"
             (key=? (key #\x 'control)   (normalize-key '(#\x ctrl))))
(test-assert "normalize list sym"
             (key=? (key 'left 'control) (normalize-key '(left control))))
(test-assert "normalize already-key"
             (key=? (key #\x 'control)   (normalize-key (key #\x 'control))))

(test-end "key")
