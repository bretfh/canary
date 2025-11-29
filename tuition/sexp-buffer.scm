;;; sexp-buffer.scm --- Buffer for sexp editing

(define-module (tuition sexp-buffer)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (<sexp-buffer>
            content
            cursor
            forward-sexp
            backward-sexp
            down-list
            up-list
            current-sexp
            insert-sexp
            delete-sexp
            format-sexp
            render-buffer-with-cursor))

;;; Buffer holds actual sexp data
(define-class <sexp-buffer> ()
  ;; Top-level list of sexps
  (content #:init-keyword #:content #:init-value '() #:accessor content)
  ;; Cursor path: list of indices into nested structure
  ;; e.g., '(0 2 1) means first top-level, third child, second child of that
  (cursor #:init-keyword #:cursor #:init-value '(0) #:accessor cursor))

(define (sexp-at-path sexps path)
  "Navigate to sexp at given path"
  (match path
    (() sexps)
    ((idx . rest)
     (if (and (list? sexps) (>= idx 0) (< idx (length sexps)))
         (sexp-at-path (list-ref sexps idx) rest)
         #f))))

(define (parent-sexp buf)
  "Get parent sexp of cursor (or #f if at top)"
  (match (cursor buf)
    ((_) #f)
    (path (sexp-at-path (content buf) (drop-right path 1)))))

(define (current-sexp buf)
  "Get the sexp at cursor position"
  (sexp-at-path (content buf) (cursor buf)))

(define (forward-sexp buf)
  "Move cursor forward one sexp (next sibling)"
  (match (cursor buf)
    ((idx)
     (let ((parent (content buf)))
       (when (and (list? parent) (< idx (- (length parent) 1)))
         (set! (cursor buf) (list (+ idx 1))))))
    (path
     (let* ((parent-path (drop-right path 1))
            (idx (last path))
            (parent (sexp-at-path (content buf) parent-path)))
       (when (and parent (list? parent) (< idx (- (length parent) 1)))
         (set! (cursor buf) (append parent-path (list (+ idx 1)))))))))

(define (backward-sexp buf)
  "Move cursor backward one sexp (prev sibling)"
  (match (cursor buf)
    ((idx) (when (> idx 0) (set! (cursor buf) (list (- idx 1)))))
    (path
     (let ((idx (last path)))
       (when (> idx 0)
         (set! (cursor buf) (append (drop-right path 1) (list (- idx 1)))))))))

(define (down-list buf)
  "Move cursor down into first child of current sexp"
  (let ((sexp (current-sexp buf)))
    (when (and sexp (pair? sexp))
      (set! (cursor buf) (append (cursor buf) '(0))))))

(define (up-list buf)
  "Move cursor up to parent sexp"
  (match (cursor buf)
    ((_) #f)
    (path (set! (cursor buf) (drop-right path 1)))))

(define (insert-sexp buf sexp)
  "Insert sexp at cursor position"
  (let* ((idx (cursor buf))
         (sexps (content buf))
         (before (take sexps idx))
         (after (drop sexps idx)))
    (set! (content buf) (append before (list sexp) after))))

(define (delete-sexp buf)
  "Delete sexp at cursor position"
  (let* ((idx (cursor buf))
         (sexps (content buf)))
    (when (and (>= idx 0) (< idx (length sexps)))
      (set! (content buf)
            (append (take sexps idx)
                    (drop sexps (+ idx 1))))
      ;; Move cursor back if we deleted the last one
      (when (>= (cursor buf) (length (content buf)))
        (set! (cursor buf) (max 0 (- (length (content buf)) 1)))))))

(define* (format-sexp sexp #:optional (indent 0))
  "Format sexp with proper indentation"
  (define (spaces n) (make-string n #\space))
  (define (atom? x) (not (pair? x)))

  (cond
   ;; Atoms just print themselves
   ((atom? sexp)
    (if (string? sexp)
        (string-append "\"" sexp "\"")
        (object->string sexp)))

   ;; Empty list
   ((null? sexp) "()")

   ;; List - format on one line if short, multiple lines if long
   (else
    (let* ((first (car sexp))
           (rest (cdr sexp))
           ;; Try one-line format first
           (one-line (call-with-output-string
                      (lambda (p)
                        (write sexp p))))
           ;; If short enough, use one line
           (use-one-line? (< (string-length one-line) 60)))

      (if use-one-line?
          one-line
          ;; Multi-line format
          (let ((indent-str (spaces indent)))
            (string-append
             "(" (format-sexp first 0)
             (if (null? rest)
                 ")"
                 (string-append
                  "\n"
                  (string-join
                   (map (lambda (x)
                          (string-append (spaces (+ indent 2))
                                         (format-sexp x (+ indent 2))))
                        rest)
                   "\n")
                  ")")))))))))

(define (collect-cells sexps)
  "Walk sexp tree, return list of (sexp . path) for every node"
  (define (walk sexp path)
    (cons (cons sexp path)
          (if (pair? sexp)
              (apply append
                     (map (lambda (i child)
                            (walk child (append path (list i))))
                          (iota (length sexp))
                          sexp))
              '())))

  (apply append
         (map (lambda (i sexp)
                (walk sexp (list i)))
              (iota (length sexps))
              sexps)))

(define* (format-sexp-tracked sexp cursor-sexp #:optional (indent 0))
  "Format sexp with stable formatting, track which sexp each line comes from"
  (define (spaces n) (make-string n #\space))
  (define (atom? x) (not (pair? x)))

  (cond
   ;; Atoms
   ((atom? sexp)
    (let ((text (if (string? sexp)
                    (string-append "\"" sexp "\"")
                    (object->string sexp))))
      (list (cons text sexp))))

   ;; Empty list
   ((null? sexp)
    (list (cons "()" sexp)))

   ;; List
   (else
    (let* ((first (car sexp))
           (rest (cdr sexp))
           (one-line (call-with-output-string (lambda (p) (write sexp p))))
           (use-one-line? (< (string-length one-line) 60)))

      (if use-one-line?
          (list (cons one-line sexp))
          ;; Multi-line
          (let* ((first-result (format-sexp-tracked first cursor-sexp 0))
                 (rest-results (map (lambda (x)
                                     (format-sexp-tracked x cursor-sexp (+ indent 2)))
                                   rest)))
            (append
             (list (cons (string-append "(" (car (car first-result)))
                         sexp))
             (cdr first-result)
             (apply append
                    (map (lambda (child-lines)
                           (map (lambda (pair)
                                  (cons (string-append (spaces (+ indent 2)) (car pair))
                                        (cdr pair)))
                                child-lines))
                         rest-results))
             (list (cons ")" sexp)))))))))

(define (render-buffer-with-cursor sexps cursor-path)
  "Render buffer with highlighting"
  (let ((cursor-sexp (sexp-at-path sexps cursor-path)))
    (define (contains? parent child)
      (or (eq? parent child)
          (and (pair? parent)
               (any (lambda (x) (contains? x child)) parent))))

    (apply append
           (map (lambda (sexp)
                  (let ((tracked-lines (format-sexp-tracked sexp cursor-sexp 0)))
                    (map (lambda (pair)
                           (let ((line-sexp (cdr pair)))
                             (cons (car pair)
                                   ;; Highlight if exact match OR if this sexp contains cursor
                                   (and cursor-sexp (contains? line-sexp cursor-sexp)))))
                         tracked-lines)))
                sexps))))
