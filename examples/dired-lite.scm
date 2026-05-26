;;; dired-lite.scm — a 2-pane file browser.
;;;
;;; Left: scrollable file list (a viewport over the directory entries).
;;; Right: a preview pane — directory listing if the cursor is on a
;;; directory, the first few KB if it's a regular file.
;;;
;;; Keys: j/k or ↑/↓ — move cursor; enter — cd into dir;
;;;       u — up one directory; q — quit.

(use-modules (canary)
             (canary components panel)
             (canary components viewport)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (oop goops))

(define +preview-bytes+ 4096)

(define (safe-read-dir path)
  (catch #t
    (lambda ()
      (let ((entries (scandir path
                              (lambda (n) (not (or (string=? n ".")
                                                   (string=? n "..")))))))
        (cons ".." (or entries '()))))
    (lambda _ '(".."))))

(define (file-is-directory? p)
  (catch #t
    (lambda () (eq? (stat:type (stat p)) 'directory))
    (lambda _ #f)))

(define (file-type p)
  (catch #t
    (lambda () (stat:type (stat p)))
    (lambda _ #f)))

(define (parent-dir p)
  (let ((slash (string-rindex p #\/)))
    (cond
     ((not slash) "/")
     ((zero? slash) "/")
     (else (substring p 0 slash)))))

(define (read-preview path)
  (catch #t
    (lambda ()
      (cond
       ((file-is-directory? path)
        (let ((entries (or (scandir path) '())))
          (string-join (take entries (min 40 (length entries))) "\n")))
       (else
        (call-with-input-file path
          (lambda (port)
            (let ((bv (get-string-n port +preview-bytes+)))
              (if (eof-object? bv) "(empty)" bv)))))))
    (lambda (key . args)
      (string-append "(can't preview: " (symbol->string key) ")"))))

(define-class <dired> ()
  (path    #:init-keyword #:path    #:init-value "/" #:accessor dired-path)
  (entries #:init-value '()                          #:accessor dired-entries)
  (cursor  #:init-value 0                            #:accessor dired-cursor)
  (preview #:init-value ""                           #:accessor dired-preview))

(define (dired-current-entry d)
  (let ((es (dired-entries d)))
    (and (not (null? es)) (list-ref es (dired-cursor d)))))

(define (dired-current-fullpath d)
  (let ((entry (dired-current-entry d)))
    (and entry
         (if (string=? entry "..")
             (parent-dir (dired-path d))
             (string-append (dired-path d) "/" entry)))))

(define (refresh-preview! d)
  (let ((p (dired-current-fullpath d)))
    (set! (dired-preview d)
          (if p (read-preview p) ""))))

(define (cd! d path)
  (set! (dired-path d) path)
  (set! (dired-entries d) (safe-read-dir path))
  (set! (dired-cursor d) 0)
  (refresh-preview! d))

(define (entry-line d i e)
  (let* ((sel?  (= i (dired-cursor d)))
         (full  (string-append (dired-path d) "/" e))
         (dir?  (or (string=? e "..") (file-is-directory? full)))
         (mark  (cond (sel? " ▶ ") (dir?  "   ") (else  "   ")))
         (face  (cond (sel? 'accent) (dir?  'note) (else  'fg))))
    (hbox (txt mark #:fg (if sel? 'accent 'muted))
          (txt e    #:fg face #:bold sel?)
          (when dir? (txt "/" #:fg 'muted)))))

(define-method (view (d <dired>))
  (let* ((es (dired-entries d))
         (items (map (lambda (e i) (entry-line d i e))
                     es
                     (iota (length es))))
         (vp (viewport #:items items
                       #:offset (max 0 (- (dired-cursor d) 3))))
         (left
          (boxed vp
                 #:title (string-append " " (dired-path d) " ")
                 #:fg 'accent))
         (right
          (boxed (flex (wrap (dired-preview d)))
                 #:title (let ((e (dired-current-entry d)))
                           (if e (string-append " " e " ") " preview "))
                 #:fg 'muted)))
    (hbox (flex left  #:grow 1)
          (flex right #:grow 2))))

(define-method (update (d <dired>) (msg <init>))
  (cd! d (dired-path d)))

(define-method (update (d <dired>) (msg <key>))
  (let ((k (key-sym msg)))
    (cond
     ((or (eqv? k #\j) (eq? k 'down))
      (set! (dired-cursor d)
            (min (max 0 (- (length (dired-entries d)) 1))
                 (+ 1 (dired-cursor d))))
      (refresh-preview! d))
     ((or (eqv? k #\k) (eq? k 'up))
      (set! (dired-cursor d) (max 0 (- (dired-cursor d) 1)))
      (refresh-preview! d))
     ((or (eq? k 'return) (eqv? k #\return))
      (let ((p (dired-current-fullpath d)))
        (when (and p (file-is-directory? p))
          (cd! d p))))
     ((or (eqv? k #\u) (eq? k 'left))
      (cd! d (parent-dir (dired-path d)))))))

(run-app (make <dired> #:path (or (getenv "HOME") "/"))
         #:title  "dired-lite"
         #:keymap (keymap (bind #\q 'quit) (bind 'escape 'quit))
         #:mouse  'off)
