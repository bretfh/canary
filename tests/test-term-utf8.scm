(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (srfi srfi-13)
             (rnrs bytevectors)
             ((gcell term types) #:prefix t:)
             ((gcell term parser) #:prefix t:)
             ((gcell term render) #:prefix t:)
             ((gcell term utf8) #:prefix u:))

(define replacement (string (integer->char #xFFFD)))

(define (row-of t y)
  (string-trim-right (t:term-dump-row t y) #\space))

(define (bv . octets)
  (u8-list->bytevector octets))

(define (decode-one bytes)
  (u:utf8-decode-bytes! (u:make-utf8-decoder) (apply bv bytes)))

(test-begin "term-utf8")

(test-group "ascii bytes decode straight through"
  (test-equal "abc"
              "abc"
              (decode-one '(97 98 99))))

(test-group "two-byte codepoint in a single chunk"
  (test-equal "é (U+00E9 = C3 A9)"
              "é"
              (decode-one '(#xC3 #xA9))))

(test-group "three-byte codepoint in a single chunk"
  (test-equal "学 (U+5B66 = E5 AD A6)"
              "学"
              (decode-one '(#xE5 #xAD #xA6))))

(test-group "four-byte codepoint in a single chunk"
  (test-equal "😀 (U+1F600 = F0 9F 98 80)"
              "😀"
              (decode-one '(#xF0 #x9F #x98 #x80))))

(test-group "codepoint split across chunks reassembles"
  (let ((d (u:make-utf8-decoder)))
    (test-equal "first chunk yields no chars"
                ""
                (u:utf8-decode-bytes! d (bv #xE5 #xAD)))
    (test-assert "decoder is mid-codepoint"
                 (u:utf8-decoder-pending? d))
    (test-equal "second chunk completes the codepoint"
                "学"
                (u:utf8-decode-bytes! d (bv #xA6)))
    (test-assert "decoder no longer pending"
                 (not (u:utf8-decoder-pending? d)))))

(test-group "lead byte alone, then continuation split into pieces"
  (let ((d (u:make-utf8-decoder)))
    (u:utf8-decode-bytes! d (bv #xF0))
    (u:utf8-decode-bytes! d (bv #x9F))
    (u:utf8-decode-bytes! d (bv #x98))
    (test-equal "final byte emits the 4-byte char"
                "😀"
                (u:utf8-decode-bytes! d (bv #x80)))))

(test-group "stray continuation byte becomes U+FFFD"
  (test-equal "lone 0x80"
              replacement
              (decode-one '(#x80))))

(test-group "invalid lead byte 0xFE becomes U+FFFD"
  (test-equal "0xFE"
              replacement
              (decode-one '(#xFE))))

(test-group "lead inside expected continuation reprocesses the new lead"
  (let* ((d (u:make-utf8-decoder))
         (out (u:utf8-decode-bytes! d (bv #xE5 #xAD #x41))))
    (test-equal "replacement then A"
                (string-append replacement "A")
                out)))

(test-group "decoder-reset! drops partial state"
  (let ((d (u:make-utf8-decoder)))
    (u:utf8-decode-bytes! d (bv #xE5 #xAD))
    (test-assert "pending before reset"
                 (u:utf8-decoder-pending? d))
    (u:utf8-decoder-reset! d)
    (test-assert "not pending after reset"
                 (not (u:utf8-decoder-pending? d)))
    (test-equal "fresh decoding starts clean"
                "A"
                (u:utf8-decode-bytes! d (bv 65)))))

(test-group "term-process-bytes! integrates with the grid"
  (let ((t (t:make-term #:width 10 #:height 2))
        (d (u:make-utf8-decoder)))
    (t:term-process-bytes! t d (bv 104 101 #xE5 #xAD))
    (t:term-process-bytes! t d (bv #xA6 33))
    (test-equal "split UTF-8 codepoint lands in the right column"
                "he学!"
                (row-of t 0))))

(test-end "term-utf8")
