;;; guix shell -m guix.scm -- zig build
;;;
;;; Provides a build env where pkg-config "guile-3.0" resolves to the
;;; static-built libguile.a + transitive deps as .a files.
;;;
;;; Upstream libunistring already ships a separate "static" output
;;; (`libunistring:static`).  The other deps don't — we add --enable-static
;;; to their configure flags so their builds produce .a alongside .so.
;;; Guile itself hardcodes --disable-static, so the with-static helper
;;; filters that out before adding --enable-static.

(use-modules (guix packages)
             (guix utils)
             (guix gexp)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages bdw-gc)
             (gnu packages libffi)
             (gnu packages multiprecision)
             (gnu packages libunistring)
             (gnu packages autotools)
             (gnu packages pkg-config)
             (gnu packages zig)
             (canary deps webui))

(define (with-static pkg)
  "Return PKG with --enable-static added (and any upstream
--disable-static stripped) so the build emits .a's alongside the .so."
  (package/inherit pkg
    (arguments
     (substitute-keyword-arguments (package-arguments pkg)
       ((#:configure-flags flags #~'())
        #~(cons "--enable-static"
                (filter (lambda (f) (not (equal? f "--disable-static")))
                        #$flags)))))))

(define libgc-static   (with-static libgc))
(define libffi-static  (with-static libffi))
(define gmp-static     (with-static gmp))
(define libtool-static (with-static libtool))

(define guile-3.0-static
  ;; Guile's autoconf sets -flto in the resulting Makefile, which makes
  ;; ar pack slim-LTO objects into libguile-3.0.a — useless without the
  ;; gcc linker plugin and Zig's bundled linker can't find one.  Pass
  ;; -ffat-lto-objects so the .a also carries native ELF, then any
  ;; linker can resolve symbols straight from it.
  (package/inherit guile-3.0
    (name "guile-static")
    (arguments
     (substitute-keyword-arguments (package-arguments guile-3.0)
       ((#:configure-flags flags #~'())
        #~(cons "--enable-static"
                (filter (lambda (f) (not (equal? f "--disable-static")))
                        #$flags)))
       ((#:make-flags flags #~'())
        #~(cons "CFLAGS=-g -O2 -ffat-lto-objects" #$flags))))
    (inputs (list libgc-static libffi-static gmp-static
                  libtool-static
                  libunistring
                  `(,libunistring "static")))))

(define guile-fibers-static
  ;; Inherit guile-fibers, build against guile-3.0-static.  Adds
  ;; --enable-static so libfibers-epoll.a lands.  Patches fibers/epoll.scm
  ;; and fibers/libevent.scm so the (dynamic-call …) is skipped once the
  ;; corresponding init has run — the static link calls init_fibers_epoll
  ;; from main(), so primitive-epoll-wake is already defined by the time
  ;; the .scm loads.
  (package/inherit guile-fibers
    (name "guile-fibers-static")
    (inputs (list guile-3.0-static))
    (arguments
     (substitute-keyword-arguments (package-arguments guile-fibers)
       ((#:configure-flags flags #~'())
        #~(cons* "--enable-static" "CFLAGS=-g -O2 -ffat-lto-objects"
                 #$flags))
       ((#:phases phases #~%standard-phases)
        #~(modify-phases #$phases
            (add-after 'unpack 'use-load-extension
              ;; substitute* is line-oriented; the call spans two lines
              ;; in events-impl.scm.  Read the file whole, rewrite via
              ;; regexp-substitute/global, write it back.  Yields:
              ;;   (load-extension (extension-library "X") "init_X")
              ;; load-extension consults the registered-extensions
              ;; table — main() calls scm_c_register_extension before
              ;; loading any Scheme, so the dlopen is bypassed and the
              ;; statically linked init runs instead.
              (lambda _
                (use-modules (ice-9 regex) (ice-9 textual-ports))
                (for-each
                 (lambda (path)
                   (when (file-exists? path)
                     (let* ((src (call-with-input-file path get-string-all))
                            (rx (make-regexp
                                 "\\(dynamic-call \"([^\"]+)\"[[:space:]]+\\(dynamic-link \\(extension-library \"([^\"]+)\"\\)\\)\\)"))
                            (out (regexp-substitute/global
                                  #f rx src
                                  'pre
                                  (lambda (m)
                                    (string-append
                                     "(load-extension (extension-library \""
                                     (match:substring m 2)
                                     "\") \""
                                     (match:substring m 1)
                                     "\")"))
                                  'post)))
                       (call-with-output-file path
                         (lambda (p) (display out p))))))
                 '("fibers/events-impl.scm"
                   "fibers/epoll.scm"
                   "fibers/libevent.scm"))))))))))

(packages->manifest
 (list zig-0.15 pkg-config
       guile-3.0-static
       libgc-static libffi-static gmp-static libtool-static
       libunistring `(,libunistring "static")
       guile-fibers-static
       ;; libwebui-2-static.a — present whether or not a given build
       ;; uses the webui backend.  build.zig only links it when
       ;; -Dbackend=webui; the dead cost otherwise is a manifest
       ;; entry, not bytes in the produced binary.
       webui))
