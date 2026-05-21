(define-module (canary image)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:export (images
            define-image!
            image-path
            image-bytes
            image-registered?
            clear-images!))

(define %sources (make-hash-table))
(define %bytes   (make-hash-table))

(define (define-image! id path)
  (hashq-set! %sources id path)
  (hashq-remove! %bytes id))

(define-syntax images
  (syntax-rules ()
    ((_ (id path) ...)
     (begin (define-image! 'id path) ...))))

(define (image-registered? id)
  (and (hashq-ref %sources id) #t))

(define (image-path id)
  (hashq-ref %sources id))

(define (image-bytes id)
  (or (hashq-ref %bytes id)
      (let ((path (hashq-ref %sources id)))
        (unless path (error "image not registered" id))
        (let* ((p  (open-file path "rb"))
               (bv (get-bytevector-all p)))
          (close-port p)
          (hashq-set! %bytes id bv)
          bv))))

(define (clear-images!)
  (hash-clear! %sources)
  (hash-clear! %bytes))
