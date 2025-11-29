;;; zones.scm --- Clickable zones with invisible markers

(define-module (tuition zones)
  #:use-module (tuition protocol)
  #:use-module (oop goops)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-69)
  #:use-module (ice-9 regex)
  #:export (zone-manager
            make-zone-manager
            zone-mark
            zone-scan
            zone-get
            zone-in-bounds?
            zone-clear
            *zone-manager*))

;;; Zone manager - tracks clickable regions
(define-record-type <zone-manager>
  (%make-zone-manager enabled? zones ids counter)
  zone-manager?
  (enabled? zone-manager-enabled? set-zone-manager-enabled!)
  (zones zone-manager-zones)      ; hash table: id -> zone-info
  (ids zone-manager-ids)          ; hash table: id -> marker
  (counter zone-manager-counter set-zone-manager-counter!))

;;; Zone info - position and bounds
(define-record-type <zone-info>
  (make-zone-info id start-x start-y end-x end-y)
  zone-info?
  (id zone-info-id)
  (start-x zone-info-start-x set-zone-info-start-x!)
  (start-y zone-info-start-y set-zone-info-start-y!)
  (end-x zone-info-end-x set-zone-info-end-x!)
  (end-y zone-info-end-y set-zone-info-end-y!))

;;; Global zone manager
(define *zone-manager* #f)

(define (make-zone-manager)
  "Create a new zone manager"
  (%make-zone-manager #t
                     (make-hash-table)
                     (make-hash-table)
                     1000))

(define (init-zone-manager!)
  "Initialize global zone manager"
  (unless *zone-manager*
    (set! *zone-manager* (make-zone-manager)))
  *zone-manager*)

;;; Zone marking - wrap text with invisible ANSI markers
(define (zone-mark id text)
  "Mark text with zone markers for mouse tracking"
  (if (or (not *zone-manager*)
          (not (zone-manager-enabled? *zone-manager*))
          (string-null? id)
          (string-null? text))
      text
      (let* ((zones (zone-manager-zones *zone-manager*))
             (ids (zone-manager-ids *zone-manager*))
             (marker (hash-table-ref/default ids id #f)))
        (unless marker
          (let ((counter (zone-manager-counter *zone-manager*)))
            (set! marker (string-append "\x1b[" (number->string counter) "z"))
            (hash-table-set! ids id marker)
            (set-zone-manager-counter! *zone-manager* (1+ counter))))
        ;; Wrap text with markers
        (string-append marker text marker))))

;;; Zone scanning - extract zone positions from rendered text
(define (zone-scan text)
  "Scan text for zone markers and extract positions"
  (if (not *zone-manager*)
      text
      (let ((zones (make-hash-table))
            (output (open-output-string))
            (x 0)
            (y 0)
            (i 0)
            (len (string-length text)))

        (let char-loop ()
          (when (< i len)
            (let ((ch (string-ref text i)))
              (cond
               ;; Escape sequence
               ((char=? ch #\esc)
                (if (and (< (1+ i) len) (char=? (string-ref text (1+ i)) #\[))
                    ;; CSI sequence - check for zone marker
                    (let ((start (+ i 2)))
                      ;; Parse number
                      (let num-loop ()
                        (when (and (< start len)
                                   (char-numeric? (string-ref text start)))
                          (set! start (1+ start))
                          (num-loop)))
                    ;; Check for 'z' terminator
                    (if (and (< start len) (char=? (string-ref text start) #\z))
                        ;; Zone marker - extract and track
                        (let* ((marker (substring text i (1+ start)))
                               (ids (zone-manager-ids *zone-manager*))
                               (id (hash-table-fold ids
                                                   (lambda (k v acc)
                                                     (if (string=? v marker) k acc))
                                                   #f)))
                          (when id
                            (let ((zone (hash-table-ref/default zones id #f)))
                              (if zone
                                  ;; End marker
                                  (begin
                                    (set-zone-info-end-x! zone (max 0 (1- x)))
                                    (set-zone-info-end-y! zone y))
                                  ;; Start marker
                                  (hash-table-set! zones id
                                                  (make-zone-info id x y 0 0)))))
                          (set! i (1+ start))
                          (char-loop))
                        ;; Regular CSI - skip entire sequence without incrementing x
                        (let skip-csi ((k (+ i 2)))
                          (if (>= k len)
                              (begin
                                (display (substring text i k) output)
                                (set! i k)
                                (char-loop))
                              (let ((code (char->integer (string-ref text k))))
                                (if (and (>= code #x40) (<= code #x7E))
                                    (begin
                                      (display (substring text i (+ k 1)) output)
                                      (set! i (+ k 1))
                                      (char-loop))
                                    (skip-csi (+ k 1))))))))
                    ;; Other escape - copy
                    (begin
                      (display ch output)
                      (set! i (1+ i))
                      (char-loop))))

               ;; Newline
               ((char=? ch #\newline)
                (display ch output)
                (set! y (1+ y))
                (set! x 0)
                (set! i (1+ i))
                (char-loop))

               ;; Regular character
               (else
                (display ch output)
                (set! x (1+ x))
                (set! i (1+ i))
                (char-loop))))))

        ;; Store zones in manager
        (when (zone-manager-enabled? *zone-manager*)
          (let ((manager-zones (zone-manager-zones *zone-manager*)))
            (hash-table-walk zones
                            (lambda (id zone)
                              (hash-table-set! manager-zones id zone)))))

        (get-output-string output))))

;;; Zone operations
(define (zone-get id)
  "Get zone info for ID"
  (and *zone-manager*
       (hash-table-ref/default (zone-manager-zones *zone-manager*) id #f)))

(define (zone-clear id)
  "Clear zone info for ID"
  (when *zone-manager*
    (hash-table-delete! (zone-manager-zones *zone-manager*) id)))

(define (zone-in-bounds? zone mouse-event)
  "Check if mouse event is within zone bounds"
  (and zone
       mouse-event
       (let ((mx (x mouse-event))
             (my (y mouse-event)))
         (and (>= mx (zone-info-start-x zone))
              (>= my (zone-info-start-y zone))
              (<= mx (zone-info-end-x zone))
              (<= my (zone-info-end-y zone))))))

;;; Initialize on load
(init-zone-manager!)
