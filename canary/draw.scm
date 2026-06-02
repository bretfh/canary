(define-module (canary draw)
  #:use-module (srfi srfi-9)
  #:export (<text-cmd>
            text-cmd?
            make-text
            text-col
            text-row
            text-str
            text-face
            text-attrs

            <cells-cmd>
            cells-cmd?
            make-cells
            cells-col
            cells-row
            cells-w
            cells-h
            cells-src-w
            cells-chars
            cells-faces

            <fill-cmd>
            fill-cmd?
            make-fill
            fill-col
            fill-row
            fill-w
            fill-h
            fill-face

            <cursor-cmd>
            cursor-cmd?
            make-cursor
            cursor-col
            cursor-row
            cursor-style

            <clear-cmd>
            clear-cmd?
            make-clear

            <image-cmd>
            image-cmd?
            make-image
            image-col
            image-row
            image-w
            image-h
            image-px
            image-py
            image-src-x
            image-src-y
            image-src-w
            image-src-h
            image-src
            image-fallback

            <clickable-cmd>
            clickable-cmd?
            make-clickable
            clickable-col
            clickable-row
            clickable-w
            clickable-h
            clickable-action
            clickable-right-action

            cmd?))

(define-record-type <text-cmd>
  (make-text col row str face attrs)
  text-cmd?
  (col text-col)
  (row text-row)
  (str text-str)
  (face text-face)
  (attrs text-attrs))

;; <cells-cmd>: a pre-rendered W×H block of cells, blitted into the
;; term in one bulk copy.  CHARS is a u32vector of code points and
;; FACES a vector of face records (or #f for default), both length
;; W*H, row-major.  Use this when an app has a dense rectangular
;; region (e.g. a roguelike map viewport) and would otherwise pay
;; for one text-cmd allocation per cell.
(define-record-type <cells-cmd>
  (%make-cells col row w h src-w chars faces)
  cells-cmd?
  (col   cells-col)
  (row   cells-row)
  (w     cells-w)
  (h     cells-h)
  ;; Source buffer's row stride.  Distinct from W: W is the
  ;; (clamped) blit rect's width; SRC-W is how wide each row of CHARS
  ;; / FACES actually is.  Without this, blitting a cells-node whose
  ;; intrinsic size exceeds the destination rect (PTY emulators
  ;; whose term-width hasn't caught up to a shrunk window) would read
  ;; rows at the wrong offsets and produce diagonal-shear garbage.
  (src-w cells-src-w)
  (chars cells-chars)
  (faces cells-faces))

(define* (make-cells col row w h chars faces #:optional (src-w #f))
  "Construct a cells-cmd.  SRC-W defaults to W (i.e. the source
buffer is exactly the size of the rect being drawn); pass the
source buffer's actual row stride when it differs."
  (%make-cells col row w h (or src-w w) chars faces))

(define-record-type <fill-cmd>
  (make-fill col row w h face)
  fill-cmd?
  (col fill-col)
  (row fill-row)
  (w fill-w)
  (h fill-h)
  (face fill-face))

(define-record-type <cursor-cmd>
  (make-cursor col row style)
  cursor-cmd?
  (col cursor-col)
  (row cursor-row)
  (style cursor-style))

(define-record-type <clear-cmd>
  (make-clear)
  clear-cmd?)

(define-record-type <image-cmd>
  (make-image col row w h px py src-x src-y src-w src-h src fallback)
  image-cmd?
  (col      image-col)
  (row      image-row)
  (w        image-w)
  (h        image-h)
  (px       image-px)
  (py       image-py)
  (src-x    image-src-x)
  (src-y    image-src-y)
  (src-w    image-src-w)
  (src-h    image-src-h)
  (src      image-src)
  (fallback image-fallback))

(define-record-type <clickable-cmd>
  (%make-clickable col row w h action right-action)
  clickable-cmd?
  (col          clickable-col)
  (row          clickable-row)
  (w            clickable-w)
  (h            clickable-h)
  (action       clickable-action)
  (right-action clickable-right-action))

(define* (make-clickable col row w h action #:optional (right-action #f))
  "Return a fresh <clickable-cmd> covering the W×H rect at (COL, ROW).
ACTION fires on a primary (left) click; the optional RIGHT-ACTION
fires on right-click, defaulting to #f (no right-click handler)."
  (%make-clickable col row w h action right-action))

(define (cmd? x)
  "Return #t if X is any draw cmd record (text, cells, fill, cursor,
clear, image, or clickable)."
  (or (text-cmd? x) (cells-cmd? x) (fill-cmd? x) (cursor-cmd? x)
      (clear-cmd? x) (image-cmd? x) (clickable-cmd? x)))
