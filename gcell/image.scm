(define-module (gcell image)
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
  "Register image symbol ID as referring to the file at PATH.  The
file is read lazily on the first `image-bytes` call.  Re-registering
ID drops any cached bytes."
  (hashq-set! %sources id path)
  (hashq-remove! %bytes id))

(define-syntax images
  (syntax-rules ()
    ((_ (id path) ...)
     (begin (define-image! 'id path) ...))))

(define (image-registered? id)
  "Return #t if image symbol ID has been registered via define-image!."
  (and (hashq-ref %sources id) #t))

(define (image-path id)
  "Return the registered path for image ID, or #f if not registered."
  (hashq-ref %sources id))

(define (image-bytes id)
  "Return the bytevector of image ID, reading the file on first
access and caching the result.  Raises an error if ID is not
registered."
  (or (hashq-ref %bytes id)
      (let ((path (hashq-ref %sources id)))
        (unless path (error "image not registered" id))
        (let* ((p  (open-file path "rb"))
               (bv (get-bytevector-all p)))
          (close-port p)
          (hashq-set! %bytes id bv)
          bv))))

(define (clear-images!)
  "Drop every registered image and its cached bytes."
  (hash-clear! %sources)
  (hash-clear! %bytes))
