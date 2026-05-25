;;; dired-lite.scm — a tiny file browser as one shareable node.
;;;
;;; Run: guile -L /path/to/guile-canary examples/dired-lite.scm
;;; Keys: j/k or ↑/↓ — move cursor; enter — cd into dir / show file;
;;;       u — up one directory; q — quit.

(use-modules (canary)
             (canary components panel)
             (ice-9 ftw)
             (srfi srfi-1)
             (oop goops))

(define (read-dir path)
  (let ((kids (scandir path
                       (lambda (n) (not (or (string=? n ".")
                                            (string=? n "..")))))))
    (cons ".." (or kids '()))))

(define (file-is-directory? p)
  (catch #t
    (lambda () (eq? (stat:type (stat p)) 'directory))
    (lambda _ #f)))

(define (parent-dir p)
  (let ((slash (string-rindex p #\/)))
    (cond
     ((not slash) "/")
     ((zero? slash) "/")
     (else (substring p 0 slash)))))

(define-class <dired> ()
  (path    #:init-keyword #:path    #:init-value "/"  #:accessor dired-path)
  (entries #:init-value '()                            #:accessor dired-entries)
  (cursor  #:init-value 0                              #:accessor dired-cursor)
  (status  #:init-value ""                             #:accessor dired-status))

(define (load-cmd d)
  (lambda () `(dired-loaded ,(read-dir (dired-path d)))))

(define-method (init (d <dired>)) (load-cmd d))

(define-method (view (d <dired>) sz)
  (let* ((es  (dired-entries d))
         (cur (dired-cursor d)))
    (vbox
     (txt (dired-path d) #:fg 'heading #:bold)
     (spacer 1)
     (cond
      ((null? es) (txt "(loading…)" #:fg 'muted #:italic))
      (else
       (apply vbox
              (map (lambda (e i)
                     (let ((sel? (= i cur)))
                       (hbox (txt (if sel? " ▶ " "   ")
                                  #:fg (if sel? 'accent 'muted))
                             (txt e
                                  #:fg (if sel? 'accent 'fg)
                                  #:bold sel?))))
                   es
                   (iota (length es))))))
     (spacer 1)
     (txt (dired-status d) #:fg 'muted #:italic))))

(define-method (update (d <dired>) (msg <key>) sz)
  (let ((k (key-sym msg))
        (es (dired-entries d))
        (cur (dired-cursor d)))
    (cond
     ((or (eqv? k #\j) (eq? k 'down))
      (set! (dired-cursor d) (min (- (length es) 1) (+ 1 cur)))
      (values d #f))
     ((or (eqv? k #\k) (eq? k 'up))
      (set! (dired-cursor d) (max 0 (- cur 1)))
      (values d #f))
     ((eq? k 'return)
      (let ((entry (and (not (null? es)) (list-ref es cur))))
        (cond
         ((not entry) (values d #f))
         ((string=? entry "..")
          (set! (dired-path d) (parent-dir (dired-path d)))
          (set! (dired-status d) "")
          (values d (load-cmd d)))
         (else
          (let ((full (string-append (dired-path d) "/" entry)))
            (cond
             ((file-is-directory? full)
              (set! (dired-path d) full)
              (set! (dired-status d) "")
              (values d (load-cmd d)))
             (else
              (set! (dired-status d) (string-append "file: " full))
              (values d #f))))))))
     (else (values d #f)))))

(define-method (update (d <dired>) msg sz)
  (cond
   ((and (pair? msg) (eq? (car msg) 'dired-loaded))
    (set! (dired-entries d) (cadr msg))
    (set! (dired-cursor d) 0)
    (values d #f))
   (else (values d #f))))

(define hint
  (make-panel #:title "keys"
              #:face  'muted
              #:content
              (vbox (txt "j / ↓   down")
                    (txt "k / ↑   up")
                    (txt "↵       enter / open")
                    (txt "u       parent")
                    (txt "q       quit"))))

(define app
  (hbox (make <dired> #:path (or (getenv "HOME") "/"))
        (spacer #:w 2)
        hint))

(run-app app
         #:title  "dired-lite"
         #:keymap (keymap (bind #\q 'quit) (bind 'escape 'quit))
         #:mouse  'off)
