(define-module (gcell term snapshot)
  #:use-module (gcell term types)
  #:use-module (gcell term parser)
  #:use-module (gcell term render)
  #:use-module (gcell draw)
  #:use-module (gcell faces)
  #:use-module (gcell render)
  #:use-module (gcell view)
  #:use-module (gcell backend-ansi)
  #:export (call-with-fresh-term
            view->grid
            term->text-snapshot
            term->ansi-snapshot
            snapshot-equal?
            replay-ansi))

;;; Commentary:
;;;
;;; Snapshot helpers for testing gcell apps and emulator behaviour.
;;; Render a tree into a <term> to inspect what it would draw without
;;; touching a real terminal; serialise the grid as text or ANSI for
;;; golden-file comparison; replay a recorded byte stream into a
;;; fresh grid for offline parsing.  All wrappers around the existing
;;; (gcell term) and (gcell render) APIs.
;;;
;;; Code:

(define* (call-with-fresh-term proc #:key (cols 80) (rows 24))
  "Allocate a fresh <term> sized COLS x ROWS, hand it to PROC, return
PROC's result.  Use to obtain a clean grid for a one-shot test or
inspection without managing the term yourself."
  (proc (make-term #:width cols #:height rows)))

(define* (view->grid node #:key (cols 80) (rows 24)
                     (theme default-faces)
                     (mouse-x -1) (mouse-y -1))
  "Render view-tree NODE into a fresh COLS x ROWS <term> via the
ANSI backend's draw pipeline and return the term.  Faces resolve
against THEME (default: the built-in default-faces alist).  Use the
returned <term>'s cells, dump, or diff for assertions."
  (let ((term (make-term #:width cols #:height rows))
        (cmds (render node cols rows #:mouse-x mouse-x #:mouse-y mouse-y)))
    (render-cmds-to-term! term cmds theme)
    term))

(define (term->text-snapshot term)
  "Return a multi-line string of TERM's visible grid with ANSI
stripped and wide-char sentinel cells skipped.  Suitable for golden-
file diffing in tests."
  (term-dump term))

(define (term->ansi-snapshot term)
  "Return an ANSI escape string that, when fed to a fresh terminal,
reproduces TERM's visible state.  Equivalent to a full repaint
diff against an empty baseline."
  (term-diff->ansi #f term))

(define (snapshot-equal? a b)
  "Return #t if snapshot strings A and B are byte-equal."
  (string=? a b))

(define* (replay-ansi bytes #:key (cols 80) (rows 24))
  "Feed BYTES (a string of already-decoded ANSI text) into a fresh
<term> sized COLS x ROWS and return the term.  Use for inspecting a
recorded terminal session or replaying a fixture."
  (let ((term (make-term #:width cols #:height rows)))
    (term-process-output! term bytes)
    term))
