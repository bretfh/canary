(define-module (canary term)
  #:use-module (canary term types)
  #:use-module (canary term ops)
  #:use-module (canary term sgr)
  #:use-module (canary term color)
  #:use-module (canary term write)
  #:use-module (canary term render)
  #:use-module (canary term parser)
  #:use-module (canary term modes)
  #:use-module (canary term utf8)
  #:use-module (canary term action)
  #:use-module (canary term dispatch)
  #:use-module (canary term base64)
  #:use-module (canary term selection)
  #:use-module (canary term snapshot)
  #:re-export
  (<term> make-term term?
   term-width term-height
   term-chars term-faces
   term-cursor-x term-cursor-y
   term-pending-wrap?
   term-cursor-style
   term-modes
   term-scroll-top term-scroll-bottom
   term-attrs term-saved-attrs
   term-title term-cwd term-last-char
   term-in-alt?
   term-input-fn term-bell-fn term-title-fn term-cwd-fn
   term-clipboard-fn term-notification-fn term-mouse-shape-fn
   set-term-input-fn!
   set-term-bell-fn! set-term-title-fn! set-term-cwd-fn!
   set-term-clipboard-fn! set-term-notification-fn! set-term-mouse-shape-fn!
   term-char-at term-face-at
   set-term-char-at! set-term-face-at! set-term-cell-at!
   term-clear! term-reset! term-resize!

   <face-attrs> make-face-attrs face-attrs?
   face-fg face-bg face-bold? face-faint? face-italic?
   face-underline face-ul-color face-blink face-inverse?
   face-conceal? face-crossed? face-overline?
   face-hyperlink face-semantic
   default-face-attrs copy-face-attrs face-attrs-equal?

   ;; Operations.
   term-cursor-up! term-cursor-down! term-cursor-left! term-cursor-right!
   term-cursor-horizontal-abs! term-cursor-vertical-abs! term-goto!
   term-save-cursor! term-restore-cursor!
   term-erase-in-line! term-erase-in-display! term-erase-char!
   term-insert-char! term-delete-char!
   term-insert-line! term-delete-line!
   term-scroll-up! term-scroll-down!
   term-horizontal-tab! term-horizontal-backtab!
   term-index! term-reverse-index! term-line-feed! term-carriage-return!
   term-set-scroll-region!
   term-enter-alt-screen! term-exit-alt-screen!

   ;; Parser entry points.
   term-process-output! term-process-bytes!

   ;; Rendering.
   term-render-line term-render-region term-dump term-dump-row
   term-render-ansi-line emit-sgr-string term-diff->ansi

   ;; Modes table.
   <mode-def> mode-def-name mode-def-number mode-def-kind mode-def-default
   *modes* mode-def-by-name mode-def-by-key
   <mode-state> make-mode-state
   mode-get mode-set! mode-save! mode-restore! mode-reset!

   ;; Stateful byte decoder.
   <utf8-decoder> make-utf8-decoder utf8-decoder?
   utf8-decoder-reset! utf8-decoder-pending? utf8-decode-bytes!

   ;; Action / op records dispatched through canary's `update` generic.
   <action> action? <action-csi> action-csi
   action-csi-fmt action-csi-params action-csi-intermediates action-csi-final
   <op> op? <op-set-mode> <op-reset-mode>
   op-set-mode op-reset-mode op-mode-number op-mode-private?
   op-mode-set-mode? op-mode-reset-mode?
   dispatch-action!

   ;; Base64 codec.
   string->base64 base64->string

   ;; Selection model.
   <selection> selection?
   selection-start-x selection-start-y selection-end-x selection-end-y
   selection-mode
   term-selection set-term-selection!
   term-selection-start! term-selection-extend! term-selection-clear!
   term-selection-text term-cell-selected?

   ;; Snapshot helpers.
   call-with-fresh-term view->grid
   term->text-snapshot term->ansi-snapshot snapshot-equal? replay-ansi))

;;; Commentary:
;;;
;;; Umbrella for canary's terminal emulator subsystem.  Importing
;;; (canary term) gives access to the public surface of the parser,
;;; cell grid, ops, mode state, action/op dispatch, selection model,
;;; snapshot helpers, and the base64 + utf8 codecs the emulator
;;; depends on.  Use (canary) for the TUI library facade; use
;;; (canary term) for emulator-as-library consumers.
;;;
;;; Code:
