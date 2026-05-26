(define-module (canary)
  #:use-module (canary engine)
  #:use-module (canary backend-ansi)
  #:use-module (canary key)
  #:use-module (canary keymap)
  #:use-module (canary layout)
  #:use-module (canary image)
  #:use-module (canary protocol)
  #:use-module (canary spring)
  #:use-module (canary theme)
  #:use-module (canary view)
  #:use-module (canary render)
  #:use-module (canary borders)
  #:use-module (canary widget)

  #:re-export
  (<focusable> widget-id update-slots
   run-app start-engine! send
   <log-entry> log-entry? log-entry-time log-entry-source
   log-entry-level log-entry-text engine-log!

   <ansi-backend> ansi-backend
   graphics? cell-w cell-h
   stats reset-stats!

   spring-animation spring-update
   spring-smooth spring-bouncy spring-gentle spring-snappy
   fps

   <key> key key? key-sym key-mods key-event key=? key->string

   view update

   <theme> theme theme?
   theme-active theme-active-name theme-resolve theme-set! theme-cycle!
   <palette> palette palette?
   default-theme

   <keymap> keymap keymap? bind keymap-step keymap-reset

   txt vbox hbox spacer join pad margin align width height fill
   place-cursor pin overlay static image on-click on-hover link
   prompt-zone input-zone output-zone flex wrap

   <border> border border? border-normal border-rounded border-thick
   border-double border-ascii boxed

   images define-image! image-registered? image-path image-bytes
   clear-images!

   <size> size size? size-width size-height
   <mouse> mouse mouse? mouse-x mouse-y mouse-button mouse-action
   <tick> tick tick? tick-n
   <resize> resize resize? resize-width resize-height
   <init> init?
   <focus> focused focused?
   <blur>  blurred blurred?
   <resume> resumed resumed?
   <paste> paste paste? paste-text
   <mount> mount mount?
   <unmount> unmount unmount?
   batch sequence batch? sequence?
   every every? after after?
   set-title cursor alt-screen mouse-mode clear-screen
   println suspend exec set-palette cycle-palette clear-log
   focus cancel

   view-size view-node?))
