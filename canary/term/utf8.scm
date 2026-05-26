;;; canary --- a TUI library for Guile
;;; Copyright © 2026 Bret Horne <bretfhorne@gmail.com>
;;;
;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

(define-module (canary term utf8)
  #:use-module (srfi srfi-9)
  #:use-module (rnrs bytevectors)
  #:export (<utf8-decoder>
            make-utf8-decoder
            utf8-decoder?
            utf8-decoder-reset!
            utf8-decoder-pending?
            utf8-decode-bytes!))

;;; Commentary:
;;;
;;; A stateful, chunk-safe UTF-8 decoder.  Bytes arrive from a PTY,
;;; file, or socket in arbitrary chunks; a multi-byte codepoint may
;;; straddle the boundary between two reads.  This decoder retains
;;; the partial codepoint across calls so callers can feed whatever
;;; bytes they have and consume whatever complete characters are
;;; ready.  Invalid bytes surface as U+FFFD (the Unicode replacement
;;; character) at the boundary they're detected.
;;;
;;; Code:

(define %replacement (integer->char #xFFFD))

(define-record-type <utf8-decoder>
  (%make-utf8-decoder acc remaining)
  utf8-decoder?
  (acc       utf8-decoder-acc       set-utf8-decoder-acc!)
  (remaining utf8-decoder-remaining set-utf8-decoder-remaining!))

(define (make-utf8-decoder)
  "Return a fresh <utf8-decoder> with no partial state."
  (%make-utf8-decoder 0 0))

(define (utf8-decoder-reset! decoder)
  "Drop any partial codepoint state held by DECODER."
  (set-utf8-decoder-acc! decoder 0)
  (set-utf8-decoder-remaining! decoder 0))

(define (utf8-decoder-pending? decoder)
  "Return #t if DECODER is mid-codepoint, i.e. it expects more
continuation bytes before the next character is ready."
  (positive? (utf8-decoder-remaining decoder)))

(define (continuation-byte? b)
  "Return #t if byte B has the 10xxxxxx UTF-8 continuation form."
  (= (logand b #xC0) #x80))

(define* (utf8-decode-bytes! decoder bv #:optional (start 0) (end #f))
  "Feed bytes [START, END) of bytevector BV through DECODER and return
the decoded characters as a string.  A partial codepoint at the end
of the chunk stays in DECODER for the next call.  Invalid bytes
produce U+FFFD."
  (define final-end (or end (bytevector-length bv)))
  (define out (open-output-string))
  (define (emit-replacement)
    (display %replacement out))
  (define (emit-codepoint cp)
    (display (integer->char cp) out))
  (let loop ((i start))
    (when (< i final-end)
      (let ((b (bytevector-u8-ref bv i)))
        (cond
         ((zero? (utf8-decoder-remaining decoder))
          (cond
           ((< b #x80)
            (emit-codepoint b)
            (loop (+ i 1)))
           ((< b #xC2)
            (emit-replacement)
            (loop (+ i 1)))
           ((< b #xE0)
            (set-utf8-decoder-acc! decoder (logand b #x1F))
            (set-utf8-decoder-remaining! decoder 1)
            (loop (+ i 1)))
           ((< b #xF0)
            (set-utf8-decoder-acc! decoder (logand b #x0F))
            (set-utf8-decoder-remaining! decoder 2)
            (loop (+ i 1)))
           ((< b #xF5)
            (set-utf8-decoder-acc! decoder (logand b #x07))
            (set-utf8-decoder-remaining! decoder 3)
            (loop (+ i 1)))
           (else
            (emit-replacement)
            (loop (+ i 1)))))
         ((not (continuation-byte? b))
          (emit-replacement)
          (utf8-decoder-reset! decoder)
          (loop i))
         (else
          (set-utf8-decoder-acc!
           decoder
           (logior (ash (utf8-decoder-acc decoder) 6)
                   (logand b #x3F)))
          (set-utf8-decoder-remaining!
           decoder
           (- (utf8-decoder-remaining decoder) 1))
          (when (zero? (utf8-decoder-remaining decoder))
            (emit-codepoint (utf8-decoder-acc decoder)))
          (loop (+ i 1)))))))
  (get-output-string out))
