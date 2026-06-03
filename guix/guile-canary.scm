(define-module (guile-canary)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (gnu packages commencement)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages guile-xyz)
  #:use-module (guile-webui))

(define-public guile-canary
  (package
    (name "guile-canary")
    (version "1.0.0")
    (source (local-file ".." "guile-canary-checkout"
                        #:recursive? #t
                        #:select? (lambda (file stat)
                                    (not (member (basename file)
                                                 '(".git" "build"))))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:make-flags #~(list "compile")
      #:modules '((guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 ftw)
                  (srfi srfi-1))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'install
            (lambda _
              (let* ((out    (assoc-ref %outputs "out"))
                     (site   (string-append out "/share/guile/site/3.0"))
                     (ccache (string-append out "/lib/guile/3.0/site-ccache")))
                (mkdir-p site)
                (mkdir-p ccache)
                (for-each (lambda (f)
                            (let ((dst (string-append site "/" f)))
                              (mkdir-p (dirname dst))
                              (copy-file f dst)))
                          (find-files "canary" "\\.scm$"))
                (copy-file "canary.scm"
                           (string-append site "/canary.scm"))
                (for-each (lambda (f)
                            (let* ((rel (substring f (string-length "build/")))
                                   (dst (string-append ccache "/" rel)))
                              (mkdir-p (dirname dst))
                              (copy-file f dst)))
                          (find-files "build" "\\.go$"))))))))
    (native-inputs (list guile-next gcc-toolchain))
    (inputs (list guile-next guile-fibers guile-webui))
    ;; guile-webui propagated so a consumer that depends on canary
    ;; gets the webui backend wired in without a second dep entry.
    (propagated-inputs (list guile-fibers guile-webui))
    (synopsis "Live-reloadable TUI library for Guile")
    (description "Elm-shaped TUI library for Guile.  Widgets compose by
embed-by-reference; the ANSI backend renders cell-diffs to a terminal, the
webui backend paints onto a browser canvas via libwebui.  Built on
guile-fibers; re-evaluating define-method / define-class updates the
running process without restart.")
    (home-page "https://github.com/bretfhorne/guile-canary")
    (license license:gpl3+)))
