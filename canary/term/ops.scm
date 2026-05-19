(define-module (canary term ops)
  #:use-module (canary term types)
  #:use-module (rnrs bytevectors)
  #:export (term-cursor-up!
            term-cursor-down!
            term-cursor-left!
            term-cursor-right!
            term-cursor-horizontal-abs!
            term-cursor-vertical-abs!
            term-goto!
            term-save-cursor!
            term-restore-cursor!
            term-erase-in-line!
            term-erase-in-display!
            term-erase-char!
            term-insert-char!
            term-delete-char!
            term-insert-line!
            term-delete-line!
            term-scroll-up!
            term-scroll-down!
            term-horizontal-tab!
            term-horizontal-backtab!
            term-index!
            term-reverse-index!
            term-line-feed!
            term-carriage-return!
            term-set-scroll-region!
            term-enter-alt-screen!
            term-exit-alt-screen!
            term-current-bg-face))

(define (clamp-min v lo)
  (if (< v lo) lo v))

(define* (term-cursor-right! term #:optional (n 1))
  (let ((n (clamp-min n 1))
        (max-x (- (term-width term) 1)))
    (set-term-cursor-x! term (min (+ (term-cursor-x term) n) max-x))))

(define* (term-cursor-left! term #:optional (n 1))
  (let ((n (clamp-min n 1)))
    (set-term-cursor-x! term (max (- (term-cursor-x term) n) 0))))

(define* (term-cursor-down! term #:optional (n 1))
  (let ((n (clamp-min n 1))
        (max-y (- (term-height term) 1)))
    (set-term-cursor-y! term (min (+ (term-cursor-y term) n) max-y))))

(define* (term-cursor-up! term #:optional (n 1))
  (let ((n (clamp-min n 1)))
    (set-term-cursor-y! term (max (- (term-cursor-y term) n) 0))))

(define* (term-cursor-horizontal-abs! term #:optional (n 1))
  (set-term-cursor-x! term (min (max (- n 1) 0) (- (term-width term) 1))))

(define* (term-cursor-vertical-abs! term #:optional (n 1))
  (set-term-cursor-y! term (min (max (- n 1) 0) (- (term-height term) 1))))

(define* (term-goto! term #:optional (y 1) (x 1))
  (set-term-cursor-y! term (min (max (- (or y 1) 1) 0) (- (term-height term) 1)))
  (set-term-cursor-x! term (min (max (- (or x 1) 1) 0) (- (term-width term) 1))))

(define (term-save-cursor! term)
  (set-term-saved-cursor-x! term (term-cursor-x term))
  (set-term-saved-cursor-y! term (term-cursor-y term))
  (set-term-saved-attrs! term (copy-face-attrs (term-attrs term))))

(define (term-restore-cursor! term)
  (set-term-cursor-x! term (term-saved-cursor-x term))
  (set-term-cursor-y! term (term-saved-cursor-y term))
  (let ((saved (term-saved-attrs term)))
    (when saved
      (let ((cur (term-attrs term)))
        (set-face-fg! cur (face-fg saved))
        (set-face-bg! cur (face-bg saved))
        (set-face-bold! cur (face-bold? saved))
        (set-face-faint! cur (face-faint? saved))
        (set-face-italic! cur (face-italic? saved))
        (set-face-underline! cur (face-underline saved))
        (set-face-ul-color! cur (face-ul-color saved))
        (set-face-blink! cur (face-blink saved))
        (set-face-inverse! cur (face-inverse? saved))
        (set-face-conceal! cur (face-conceal? saved))
        (set-face-crossed! cur (face-crossed? saved))))))

(define (term-current-bg-face term)
  (and (face-bg (term-attrs term))
       (let ((cur (term-attrs term))
             (cached (term-last-write-face term)))
         (if (and cached (face-attrs-equal? cached cur))
             cached
             (let ((c (copy-face-attrs cur)))
               (set-term-last-write-face! term c)
               c)))))

(define %space (char->integer #\space))

(define (fill-cells! chars faces start end face)
  (do ((i start (+ i 1)))
      ((= i end))
    (u32vector-set! chars i %space)
    (vector-set!    faces i face)))

(define* (term-erase-in-line! term #:optional (mode 0))
  (let* ((y (term-cursor-y term))
         (x (term-cursor-x term))
         (w (term-width term))
         (chars (term-chars term))
         (faces (term-faces term))
         (base (* y w))
         (face (term-current-bg-face term)))
    (case mode
      ((0) (fill-cells! chars faces (+ base x) (+ base w) face))
      ((1) (fill-cells! chars faces base (+ base x 1) face))
      ((2) (fill-cells! chars faces base (+ base w) face)))))

(define* (term-erase-in-display! term #:optional (mode 0))
  (let* ((y (term-cursor-y term))
         (h (term-height term))
         (w (term-width term))
         (chars (term-chars term))
         (faces (term-faces term))
         (face  (term-current-bg-face term)))
    (case mode
      ((0)
       (term-erase-in-line! term 0)
       (fill-cells! chars faces (* (+ y 1) w) (* h w) face))
      ((1)
       (fill-cells! chars faces 0 (* y w) face)
       (term-erase-in-line! term 1))
      ((2 3)
       (term-clear! term face)
       (when (= mode 3)
         (set-term-scrollback-size! term 0))))))

(define* (term-erase-char! term #:optional (n 1))
  (let* ((n (clamp-min n 1))
         (y (term-cursor-y term))
         (x (term-cursor-x term))
         (w (term-width term))
         (chars (term-chars term))
         (faces (term-faces term))
         (count (min n (- w x)))
         (face (term-current-bg-face term))
         (base (* y w)))
    (fill-cells! chars faces (+ base x) (+ base x count) face)))

(define (shift-row! chars faces base from to count)
  "Within one row at offset BASE, copy COUNT cells from FROM to TO. Handles overlap."
  (cond
   ((= from to) #f)
   ((< from to)
    (do ((i (- count 1) (- i 1)))
        ((< i 0))
      (let ((si (+ base from i))
            (di (+ base to   i)))
        (u32vector-set! chars di (u32vector-ref chars si))
        (vector-set!    faces di (vector-ref    faces si)))))
   (else
    (do ((i 0 (+ i 1)))
        ((= i count))
      (let ((si (+ base from i))
            (di (+ base to   i)))
        (u32vector-set! chars di (u32vector-ref chars si))
        (vector-set!    faces di (vector-ref    faces si)))))))

(define* (term-insert-char! term #:optional (n 1))
  (let* ((n (clamp-min n 1))
         (y (term-cursor-y term))
         (x (term-cursor-x term))
         (w (term-width term))
         (count (min n (- w x)))
         (face (term-current-bg-face term))
         (chars (term-chars term))
         (faces (term-faces term))
         (base (* y w))
         (move-count (- w x count)))
    (when (positive? move-count)
      (shift-row! chars faces base x (+ x count) move-count))
    (fill-cells! chars faces (+ base x) (+ base x count) face)))

(define* (term-delete-char! term #:optional (n 1))
  (let* ((n (clamp-min n 1))
         (y (term-cursor-y term))
         (x (term-cursor-x term))
         (w (term-width term))
         (count (min n (- w x)))
         (face (term-current-bg-face term))
         (chars (term-chars term))
         (faces (term-faces term))
         (base (* y w))
         (move-count (- w x count)))
    (when (positive? move-count)
      (shift-row! chars faces base (+ x count) x move-count))
    (fill-cells! chars faces (+ base (- w count)) (+ base w) face)))

(define (snapshot-row term y)
  (let* ((w (term-width term))
         (chars (term-chars term))
         (faces (term-faces term))
         (base (* y w))
         (cs (make-u32vector w))
         (fs (make-vector w #f)))
    (do ((i 0 (+ i 1)))
        ((= i w))
      (u32vector-set! cs i (u32vector-ref chars (+ base i)))
      (vector-set!    fs i (vector-ref    faces (+ base i))))
    (cons cs fs)))

(define (push-scrollback! term y)
  (let ((sb (term-scrollback term))
        (max-sb (term-max-scrollback term)))
    (when (and sb (positive? max-sb))
      (when (>= (term-scrollback-size term) (vector-length sb))
        (let* ((cap (vector-length sb))
               (new-cap (min (* 2 (max cap 64)) max-sb))
               (new (make-vector new-cap #f)))
          (do ((i 0 (+ i 1)))
              ((= i (term-scrollback-size term)))
            (vector-set! new i (vector-ref sb i)))
          (set-term-scrollback! term new)
          (set! sb new)))
      (when (< (term-scrollback-size term) max-sb)
        (vector-set! sb (term-scrollback-size term) (snapshot-row term y))
        (set-term-scrollback-size! term (+ (term-scrollback-size term) 1))))))

(define (copy-line! term src-y dst-y)
  (term-copy-row! term src-y dst-y))

(define* (term-scroll-up! term #:optional (n 1))
  (let* ((n (clamp-min n 1))
         (top (term-scroll-top term))
         (bot (term-scroll-bottom term))
         (region-height (+ 1 (- bot top)))
         (count (min n region-height)))
    (when (positive? count)
      (when (and (zero? top) (not (term-in-alt? term)))
        (do ((i 0 (+ i 1)))
            ((= i count))
          (push-scrollback! term (+ top i))))
      (do ((y top (+ y 1)))
          ((> y (- bot count)))
        (copy-line! term (+ y count) y))
      (do ((y (max top (- bot count -1)) (+ y 1)))
          ((> y bot))
        (term-clear-row! term y)))))

(define* (term-scroll-down! term #:optional (n 1))
  (let* ((n (clamp-min n 1))
         (top (term-scroll-top term))
         (bot (term-scroll-bottom term))
         (region-height (+ 1 (- bot top)))
         (count (min n region-height)))
    (when (positive? count)
      (do ((y bot (- y 1)))
          ((< y (+ top count)))
        (copy-line! term (- y count) y))
      (do ((y top (+ y 1)))
          ((>= y (+ top count)))
        (term-clear-row! term y)))))

(define* (term-insert-line! term #:optional (n 1))
  (let ((n (clamp-min n 1))
        (y (term-cursor-y term))
        (top (term-scroll-top term))
        (bot (term-scroll-bottom term)))
    (when (and (>= y top) (<= y bot))
      (let ((old-top top))
        (set-term-scroll-top! term y)
        (term-scroll-down! term (min n (+ 1 (- bot y))))
        (set-term-scroll-top! term old-top)))))

(define* (term-delete-line! term #:optional (n 1))
  (let ((n (clamp-min n 1))
        (y (term-cursor-y term))
        (top (term-scroll-top term))
        (bot (term-scroll-bottom term)))
    (when (and (>= y top) (<= y bot))
      (let ((old-top top))
        (set-term-scroll-top! term y)
        (term-scroll-up! term (min n (+ 1 (- bot y))))
        (set-term-scroll-top! term old-top)))))

(define* (term-horizontal-tab! term #:optional (n 1))
  (let* ((n (clamp-min n 1))
         (x (term-cursor-x term))
         (w (term-width term))
         (next-tab (+ x (- 8 (modulo x 8)))))
    (do ((i 1 (+ i 1)))
        ((= i n))
      (set! next-tab (+ next-tab 8)))
    (set-term-cursor-x! term (min next-tab (- w 1)))))

(define* (term-horizontal-backtab! term #:optional (n 1))
  (let* ((n (clamp-min n 1))
         (x (term-cursor-x term))
         (prev-tab (if (zero? (modulo x 8))
                       (- x 8)
                       (- x (modulo x 8)))))
    (do ((i 1 (+ i 1)))
        ((= i n))
      (set! prev-tab (- prev-tab 8)))
    (set-term-cursor-x! term (max prev-tab 0))))

(define (term-index! term)
  (let ((y (term-cursor-y term))
        (bot (term-scroll-bottom term)))
    (cond
     ((= y bot) (term-scroll-up! term 1))
     ((< y (- (term-height term) 1))
      (set-term-cursor-y! term (+ y 1))))))

(define (term-reverse-index! term)
  (let ((y (term-cursor-y term))
        (top (term-scroll-top term)))
    (cond
     ((= y top) (term-scroll-down! term 1))
     ((> y 0)
      (set-term-cursor-y! term (- y 1))))))

(define (term-line-feed! term)
  (let* ((y (term-cursor-y term))
         (bot (term-scroll-bottom term)))
    (set-term-cursor-x! term 0)
    (cond
     ((= y bot) (term-scroll-up! term 1))
     ((< y (- (term-height term) 1))
      (set-term-cursor-y! term (+ y 1))))))

(define (term-carriage-return! term)
  (set-term-cursor-x! term 0))

(define* (term-set-scroll-region! term #:optional top bottom)
  (let ((tv (or top 1))
        (bv (or bottom (term-height term))))
    (when (and (< 0 tv) (< tv bv) (<= bv (term-height term)))
      (set-term-scroll-top! term (- tv 1))
      (set-term-scroll-bottom! term (- bv 1))
      (term-goto! term 1 1))))

(define (term-enter-alt-screen! term)
  (unless (term-in-alt? term)
    (let* ((w (term-width term))
           (h (term-height term))
           (n (* w h)))
      (set-term-main-chars! term (term-chars term))
      (set-term-main-faces! term (term-faces term))
      (set-term-chars! term (make-u32vector n %space))
      (set-term-faces! term (make-vector n #f))
      (set-term-in-alt! term #t)
      (term-goto! term 1 1))))

(define (term-exit-alt-screen! term)
  (when (term-in-alt? term)
    (set-term-chars! term (term-main-chars term))
    (set-term-faces! term (term-main-faces term))
    (set-term-main-chars! term #f)
    (set-term-main-faces! term #f)
    (set-term-in-alt! term #f)))
