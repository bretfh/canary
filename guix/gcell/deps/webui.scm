(define-module (gcell deps webui)
  #:use-module (guix build-system gnu)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix licenses)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages commencement)
  #:export (webui))

;;; Commentary:
;;;
;;; Guix package for the webui C library
;;; (https://github.com/webui-dev/webui).  gcell's backend-webui
;;; loads libwebui-2.so via Guile's (system foreign) FFI, so the
;;; profile must contain this lib for the webui backend to work.
;;;
;;; Code:

(define-public webui
  (package
    (name "webui")
    (version "2.5.0-beta.4")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/webui-dev/webui")
             (commit "dadf4175d6f2c4060b7a27a32e6e9e64e647116f")))
       (file-name (git-file-name name version))
       (sha256
        (base32
         "1s0963crmakxnfmzsykyq25i6ab59ynp017gxjbw8iyflaybbp4d"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:make-flags
      #~(list (string-append "CC=" #$(cc-for-target)))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda* (#:key make-flags #:allow-other-keys)
              ;; Ship the debug build.  Release (-O2) has a race that
              ;; makes webui_show_wv silently return false on Linux GTK
              ;; webview; the debug build (-g, no -O, -DWEBUI_LOG) has
              ;; enough printf serialisation that the wv thread reliably
              ;; flips is_webview_mode inside the 2.5s window.  The
              ;; size penalty (~200KB) is irrelevant for a local-only
              ;; UI bridge.
              (apply invoke "make" "-f" "GNUmakefile" "debug" make-flags)))
          (replace 'install
            (lambda* (#:key outputs #:allow-other-keys)
              (let* ((out     (assoc-ref outputs "out"))
                     (lib     (string-append out "/lib"))
                     (include (string-append out "/include")))
                (mkdir-p lib)
                (mkdir-p include)
                (install-file "dist/debug/libwebui-2.so" lib)
                (install-file "dist/debug/libwebui-2-static.a" lib)
                (install-file "include/webui.h" include)))))))
    (home-page "https://webui.me")
    (synopsis "Local HTTP+WebSocket server with browser-as-GUI bridge")
    (description "webui is a small C library that embeds an HTTP and
WebSocket server on localhost and launches an installed web browser in
app mode pointed at it.  The host program then drives the browser as a
GUI surface through a fast binary protocol, without bundling a
WebView.")
    (license expat)))
