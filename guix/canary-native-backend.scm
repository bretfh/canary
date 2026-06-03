(define-module (canary-native-backend)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (gnu packages commencement)
  #:use-module (gnu packages fontutils)
  #:use-module (gnu packages fonts)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages zig)
  #:use-module (guile-canary))

(define-public canary-native-backend
  (package
    (name "canary-native-backend")
    (version "1.0.0")
    (source (local-file ".." "canary-native-backend-checkout"
                        #:recursive? #t
                        #:select? (lambda (file stat)
                                    (not (member (basename file)
                                                 '(".git" "build"
                                                   "zig-out" ".zig-cache"))))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          ;; Zig builds: pin the cache inside the build tree, then run
          ;; `zig build -Dfont-dir=...` so the font path is baked into
          ;; libcanary-native.so.  No CANARY_NATIVE_FONT_DIR env var
          ;; needed at runtime.
          (replace 'build
            (lambda* (#:key inputs #:allow-other-keys)
              (setenv "ZIG_GLOBAL_CACHE_DIR"
                      (string-append (getcwd) "/.zig-cache"))
              (setenv "ZIG_LOCAL_CACHE_DIR"
                      (string-append (getcwd) "/.zig-local"))
              (with-directory-excursion "canary/backend-native"
                (invoke "zig" "build"))
              ;; Compile backend-native.scm against the freshly built
              ;; libcanary-native.so so its FFI lookups resolve.
              (setenv "LD_LIBRARY_PATH"
                      (string-append (getcwd)
                                     "/canary/backend-native/zig-out/lib"))
              (invoke "guild" "compile" "-L" "."
                      "-o" "build/canary/backend-native.go"
                      "canary/backend-native.scm")))
          ;; Don't validate-runpath: the Zig .so has no RUNPATH entry
          ;; matching the validator's expectations.
          (delete 'validate-runpath)
          (replace 'install
            (lambda* (#:key outputs #:allow-other-keys)
              (let* ((out  (assoc-ref outputs "out"))
                     (site (string-append out "/share/guile/site/3.0/canary"))
                     (cc   (string-append out
                                          "/lib/guile/3.0/site-ccache/canary"))
                     (lib  (string-append out "/lib")))
                (mkdir-p site)
                (mkdir-p cc)
                (mkdir-p lib)
                (install-file "canary/backend-native.scm" site)
                (install-file "build/canary/backend-native.go" cc)
                (install-file "canary/backend-native/zig-out/lib/libcanary-native.so"
                              lib)))))))
    (native-inputs
     (list guile-next gcc-toolchain pkg-config zig-0.14))
    (inputs
     ;; Build-time only: libcanary-native.so is linked against these and
     ;; the loader at runtime resolves them from the user's profile.
     ;; glfw-3.4 specifically -- the runtime GLFW_PLATFORM init hint
     ;; (used to force Wayland) was added in 3.4.
     (list guile-next glfw-3.4 freetype libepoxy mesa font-dejavu))
    ;; guile-canary propagated so consumers get the whole canary load
    ;; path; font-dejavu propagated so the baked font path stays valid
    ;; in the consumer's profile lifecycle.
    (propagated-inputs
     (list guile-canary font-dejavu glfw-3.4 freetype libepoxy mesa))
    (synopsis "Native (glfw + freetype + GL 3.3) backend for canary")
    (description "Adds (canary backend-native) to canary's load path: a
backend that opens a native window via glfw and renders canary's cell
grid through a custom OpenGL 3.3 core pipeline with a 3-layer
sampler2DArray TTF atlas (regular/bold/oblique).  Matches the
capability of canary's WebGL2 webui client without embedding a
browser engine; baseline footprint roughly ~100 MB resident, down
from webui's ~250 MB.")
    (home-page "https://github.com/bretfhorne/guile-canary")
    (license license:gpl3+)))
