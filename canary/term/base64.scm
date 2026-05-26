(define-module (canary term base64)
  #:use-module (rnrs bytevectors)
  #:export (string->base64
            base64->string))

;;; Commentary:
;;;
;;; A minimal RFC 4648 base64 codec for OSC 52 clipboard payloads.
;;; Operates on Scheme strings end-to-end: the input string's bytes
;;; (interpreted as Latin-1 / a-byte-per-char) are encoded; a decode
;;; returns a string of the decoded bytes in the same byte-per-char
;;; form.  For UTF-8 payloads, callers handle decoding upstream.
;;;
;;; Code:

(define %alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define %reverse
  (let ((v (make-vector 128 #f)))
    (let loop ((i 0))
      (when (< i 64)
        (vector-set! v (char->integer (string-ref %alphabet i)) i)
        (loop (+ i 1))))
    v))

(define (string->base64 s)
  "Encode the bytes of STR (one byte per char) as a base64 string per
RFC 4648.  Output is padded with '=' to a multiple of four chars."
  (let* ((n (string-length s))
         (out (open-output-string)))
    (let loop ((i 0))
      (cond
       ((>= i n) (get-output-string out))
       (else
        (let* ((b0 (char->integer (string-ref s i)))
               (b1 (and (< (+ i 1) n)
                        (char->integer (string-ref s (+ i 1)))))
               (b2 (and (< (+ i 2) n)
                        (char->integer (string-ref s (+ i 2))))))
          (display (string-ref %alphabet (ash b0 -2)) out)
          (display (string-ref %alphabet
                               (logior (ash (logand b0 #b11) 4)
                                       (ash (or b1 0) -4)))
                   out)
          (display (if b1
                       (string-ref %alphabet
                                   (logior (ash (logand b1 #b1111) 2)
                                           (ash (or b2 0) -6)))
                       #\=)
                   out)
          (display (if b2
                       (string-ref %alphabet (logand b2 #b111111))
                       #\=)
                   out)
          (loop (+ i 3))))))))

(define (decode-quad c0 c1 c2 c3 out)
  "Decode a single 4-char base64 quad C0..C3 into OUT, omitting bytes
that pair with '=' padding."
  (let ((v0 (vector-ref %reverse (char->integer c0)))
        (v1 (vector-ref %reverse (char->integer c1)))
        (v2 (and (not (char=? c2 #\=))
                 (vector-ref %reverse (char->integer c2))))
        (v3 (and (not (char=? c3 #\=))
                 (vector-ref %reverse (char->integer c3)))))
    (when (and v0 v1)
      (display (integer->char (logior (ash v0 2) (ash v1 -4))) out)
      (when v2
        (display (integer->char (logior (ash (logand v1 #b1111) 4)
                                        (ash v2 -2)))
                 out)
        (when v3
          (display (integer->char (logior (ash (logand v2 #b11) 6) v3))
                   out))))))

(define (base64->string s)
  "Decode the base64 string S (with optional '=' padding) into a
string of bytes (one byte per char).  Ignores any whitespace; returns
the empty string for malformed input."
  (let* ((clean (string-fold-right
                 (lambda (c acc)
                   (cond
                    ((char-whitespace? c) acc)
                    (else (cons c acc))))
                 '() s))
         (vec (list->vector clean))
         (n   (vector-length vec))
         (out (open-output-string)))
    (cond
     ((not (zero? (modulo n 4))) "")
     (else
      (let loop ((i 0))
        (cond
         ((>= i n) (get-output-string out))
         (else
          (decode-quad (vector-ref vec i)
                       (vector-ref vec (+ i 1))
                       (vector-ref vec (+ i 2))
                       (vector-ref vec (+ i 3))
                       out)
          (loop (+ i 4)))))))))
