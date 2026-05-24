(define-module (canary)
  #:use-module (canary app)
  #:use-module (canary backend-ansi)
  #:use-module (canary component)
  #:use-module (canary key)
  #:use-module (canary keymap)
  #:use-module (canary layout)
  #:use-module (canary image)
  #:use-module (canary protocol)
  #:use-module (canary spring)
  #:use-module (canary theme)
  #:use-module (canary view)

  #:re-export
  (;; app
   <app> run-app start-app! init update view send
   <log-entry> log-entry? log-entry-time log-entry-source
   log-entry-level log-entry-text
   log! clear-log! with-engine-error render-log
   app-keymap app-backend app-theme app-title app-running?
   app-log-entries app-show-log? app-log-cap app-log-height-frac
   set-app-keymap!
   at tail-from first second third fourth fifth
   sixth seventh eighth ninth tenth rest define-positions

   ;; backend
   <ansi-backend> make-ansi-backend
   graphics? cell-w cell-h
   stats reset-stats!

   ;; spring physics
   make-spring-animation spring-update
   make-spring-smooth make-spring-bouncy make-spring-gentle make-spring-snappy
   fps

   ;; key
   <key> key key? key-sym key-mods key=? key->string

   ;; component
   <component> react component-focused? component-focus! component-blur!

   ;; theme — the user-facing way to declare named colors
   <theme> theme theme?
   theme-active theme-active-name theme-resolve theme-set! theme-cycle!
   <palette> palette palette?
   default-theme

   ;; keymap
   <keymap> keymap keymap? bind keymap-step keymap-reset

   ;; layout — the user-facing way to build views
   txt vbox hbox spacer join pad margin align width height fill
   place-cursor pin overlay static image on-click

   ;; image — asset registry
   images define-image! image-registered? image-path image-bytes
   clear-images!

   ;; protocol
   <size> size size? size-width size-height
   <mouse> mouse mouse? mouse-x mouse-y mouse-button mouse-action
   <tick> tick tick? tick-n
   <resize> resize resize? resize-width resize-height
   batch sequence batch? sequence?
   every every?
   after after?
   set-palette cycle-palette clear-log

   ;; view — just types/predicates/view-size, not the make-*-node factories
   view-size view-node?))
