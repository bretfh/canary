;;; Dev-shell manifest.  Invoke with
;;;   guix shell -m manifest.scm
;;; once ~/.config/guix/channels.scm has been pulled (the
;;; bfh-dots, guile-webui, and guile-canary channels supply
;;; webui, canary-native-backend, and the canary core).
;;; For in-progress edits not yet on a pulled channel:
;;;   guix shell -L guix -L ~/dots/channel -m manifest.scm

(use-modules (gnu packages commencement)
             (gnu packages gtk)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages version-control)
             (gnu packages web)
             (gnu packages webkit)
             (etc packages webui)
             (canary-native-backend))

(packages->manifest
 (list guile-next
       guile-fibers
       webui
       ;; libwebui's webview path dlopens libgtk-3.so.0 plus
       ;; libwebkit2gtk-4.1.so.0 (with fallback to -4.0.so.37) at
       ;; runtime — see webui.c:GTK_RUNTIME_ARR / WEBKIT_RUNTIME_ARR.
       ;; Both have to be on LD_LIBRARY_PATH or the webview show is a
       ;; silent no-op and the window stays blank.
       gtk+
       webkitgtk-for-gtk3
       ;; Native backend: glfw + freetype + libepoxy on Wayland.  The
       ;; package propagates guile-canary, font-dejavu, glfw-3.4, etc.
       ;; so `guile examples/clock-native.scm` runs straight out of
       ;; this shell with no extra env vars.
       canary-native-backend
       gcc-toolchain
       gnu-make
       git))
