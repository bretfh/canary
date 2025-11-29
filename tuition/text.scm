;;; text.scm --- ANSI-aware text utilities

(define-module (tuition text)
  #:export (visible-length
            join-lines
            nl))

(define (visible-length str)
  (let ((result 0)
        (i 0)
        (len (string-length str)))
    (let loop ((i 0) (result 0))
      (if (>= i len)
          result
          (let ((char (string-ref str i)))
            (cond
             ((char=? char #\escape)
              (let skip-esc ((j (+ i 1)))
                (cond
                 ((>= j len) (loop j result))
                 ((char=? (string-ref str j) #\[)
                  (let skip-csi ((k (+ j 1)))
                    (cond
                     ((>= k len) (loop k result))
                     (else
                      (let ((code (char->integer (string-ref str k))))
                        (if (and (>= code #x40) (<= code #x7E))
                            (loop (+ k 1) result)
                            (skip-csi (+ k 1))))))))
                 (else (loop j result)))))
             ((char=? char #\return)
              (loop (+ i 1) result))
             (else (loop (+ i 1) (+ result 1)))))))))

(define nl "\r\n")

(define (join-lines . lines)
  (string-join lines nl))
