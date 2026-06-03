;;; Dev-shell manifest.  Invoke with
;;;   guix shell -L ~/dots -m manifest.scm

(use-modules (gnu packages commencement)
             (gnu packages gtk)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages version-control)
             (gnu packages web)
             (gnu packages webkit)
             (etc packages webui))

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
       gcc-toolchain
       gnu-make
       git))
