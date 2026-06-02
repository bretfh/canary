(define-module (canary components menu)
  #:use-module (canary view)
  #:use-module (canary layout)
  #:use-module (canary borders)
  #:use-module (canary protocol)
  #:use-module (canary key)
  #:use-module (canary widget)
  #:use-module ((srfi srfi-1)  #:select (iota))
  #:use-module (srfi srfi-9)
  #:use-module (oop goops)
  #:export (<menu>
            menu? menu
            menu-items menu-focus menu-title menu-cols menu-show-help?
            menu-help-face menu-arrow-face menu-row-face menu-hot-face
            <menu-item>
            make-menu-item menu-item menu-item?
            menu-item-label menu-item-action menu-item-hotkey))

;;; A focusable list of choices.  An item is `(label, action, hotkey)`;
;;; the menu owns the current focus.  Navigation:
;;;   - up/down (and k/j)             move focus
;;;   - enter                          send the focused item's action
;;;   - hot-letter (any item's hotkey) send that item's action
;;;   - mouse click on a row           send that item's action (via on-click)
;;;
;;; ACTION can be anything an app's `update` dispatches on: a symbol, a
;;; tagged-list cmd, a GOOPS msg instance, etc.  When the menu fires it,
;;; it's enqueued via `send` so the cascade delivers it to every widget
;;; in the tree.  The parent widget specialises `update` on the action's
;;; class / value to react.

(define-record-type <menu-item>
  (make-menu-item label action hotkey)
  menu-item?
  (label  menu-item-label)
  (action menu-item-action)
  (hotkey menu-item-hotkey))

(define (menu-item label action)
  "Build a `<menu-item>` whose hotkey is the lowercased first char of
LABEL.  Use `make-menu-item` directly for a non-leading hotkey."
  (make-menu-item label action
                  (char-downcase (string-ref label 0))))

(define-class <menu> (<focusable>)
  (items       #:init-keyword #:items       #:init-value '()           #:getter menu-items)
  (focus       #:init-keyword #:focus       #:init-value 0             #:getter menu-focus)
  (title       #:init-keyword #:title       #:init-value #f            #:getter menu-title)
  (cols        #:init-keyword #:cols        #:init-value 28            #:getter menu-cols)
  (show-help?  #:init-keyword #:show-help?  #:init-value #t            #:getter menu-show-help?)
  (help-face   #:init-keyword #:help-face   #:init-value 'muted        #:getter menu-help-face)
  (arrow-face  #:init-keyword #:arrow-face  #:init-value 'accent       #:getter menu-arrow-face)
  (row-face    #:init-keyword #:row-face    #:init-value 'bone         #:getter menu-row-face)
  (hot-face    #:init-keyword #:hot-face    #:init-value 'accent       #:getter menu-hot-face))

(define (menu? x) (is-a? x <menu>))

(define (menu . args)
  "Return a fresh `<menu>` initialised from ARGS (sequence of #:items,
#:focus, #:title, #:cols, #:show-help?, face overrides)."
  (apply make <menu> args))

(define (item-row m item focused?)
  (let* ((label   (menu-item-label item))
         (head    (string-ref label 0))
         (rest    (substring label 1))
         (arrow   (cond
                   (focused? (txt "> " #:fg (menu-arrow-face m) #:bold))
                   (else     (txt "  " #:fg 'dim))))
         (rest-fg (cond (focused? (menu-arrow-face m)) (else (menu-row-face m)))))
    (hbox arrow
          (txt (string head) #:fg (menu-hot-face m) #:bold #:underline)
          (txt rest #:fg rest-fg #:bold (if focused? #t #f)))))

(define-method (view (m <menu>))
  "Render the menu inside a `boxed` of WIDTH (menu-cols).  Each row is
wrapped in `on-click` so a mouse press sends the item's action; the
focused row gets the arrow indicator."
  (let* ((items   (menu-items m))
         (focus   (menu-focus m))
         (rows    (map (lambda (item idx)
                         (on-click (item-row m item (= idx focus))
                                   #:action (menu-item-action item)))
                       items
                       (iota (length items))))
         (help    (and (menu-show-help? m)
                       (align (txt "up/down . enter . esc"
                                    #:fg (menu-help-face m) #:italic)
                              #:h 'center)))
         (body    (apply vbox
                         (cond
                          (help (append rows (list (spacer 1) help)))
                          (else rows)))))
    (width
     (cond
      ((menu-title m)
       (boxed body #:border border-rounded
              #:fg (menu-help-face m)
              #:title (menu-title m)))
      (else
       (boxed body #:border border-rounded
              #:fg (menu-help-face m))))
     (menu-cols m))))

(define (mod-prev m)
  (let ((n (length (menu-items m))))
    (cond ((zero? n) 0) (else (modulo (- (menu-focus m) 1) n)))))

(define (mod-next m)
  (let ((n (length (menu-items m))))
    (cond ((zero? n) 0) (else (modulo (+ (menu-focus m) 1) n)))))

(define (item-at m idx)
  (and (pair? (menu-items m)) (list-ref (menu-items m) idx)))

(define (find-hot m c)
  "Return the item whose hotkey is char C, or #f if none."
  (let lp ((rest (menu-items m)))
    (cond
     ((null? rest) #f)
     ((eqv? (menu-item-hotkey (car rest)) c) (car rest))
     (else (lp (cdr rest))))))

(define (fire-action action)
  "Return a cmd that sends ACTION as a msg so it cascades through the
tree on the next event-loop iteration.  Producer-thunk cmds are
already understood by the engine."
  (lambda () action))

(define-method (update (m <menu>) (msg <key>))
  "Navigate the menu with arrow keys, j/k, page-up/down; select via
enter or a hot letter; emit `'menu-close` on escape so ancestors can
react (clearing a pause-menu overlay slot, exiting auth, …).

Only acts on `'press` events.  Kitty's progressive-enhancement
`report-event-types` flag also delivers `'release` and `'repeat`; a
single tap on a terminal whose OS auto-repeat fires before release
would otherwise cycle the menu twice."
  (cond
   ((not (eq? (key-event msg) 'press)) (cons m #f))
   (else
    (let ((k (key-sym msg)))
    (cond
     ((or (eq? k 'up)   (eqv? k #\k))
      (cons (update-slots m #:focus (mod-prev m)) #f))
     ((or (eq? k 'down) (eqv? k #\j))
      (cons (update-slots m #:focus (mod-next m)) #f))
     ((or (eq? k 'home) (eq? k 'page-up))
      (cons (update-slots m #:focus 0) #f))
     ((or (eq? k 'end)  (eq? k 'page-down))
      (cons (update-slots m #:focus (max 0 (- (length (menu-items m)) 1))) #f))
     ((eq? k 'enter)
      (cond
       ((item-at m (menu-focus m))
        => (lambda (item) (cons m (fire-action (menu-item-action item)))))
       (else (cons m #f))))
     ((eq? k 'escape)
      (cons m (fire-action 'menu-close)))
     ((and (char? k) (null? (key-mods msg)))
      (cond
       ((find-hot m (char-downcase k))
        => (lambda (item) (cons m (fire-action (menu-item-action item)))))
       (else (cons m #f))))
     (else (cons m #f)))))))
