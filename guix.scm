(use-modules (guix packages)
             (guix gexp)
             (guix git-download)
             (guix build-system gnu)
             ((guix licenses) #:prefix l:)
             (gnu packages commencement)
             (gnu packages guile)
             (gnu packages guile-xyz))

(define %canary-checkout
  (dirname (current-filename)))

(define %canary-source
  (local-file %canary-checkout
              "guile-canary-source"
              #:recursive? #t
              #:select? (git-predicate %canary-checkout)))

(define-public guile-canary
  (package
    (name "guile-canary")
    (version "0.1.0")
    (source %canary-source)
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
              (let* ((out (assoc-ref %outputs "out"))
                     (site (string-append out "/share/guile/site/3.0"))
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
    (inputs (list guile-next guile-fibers))
    (propagated-inputs (list guile-fibers))
    (synopsis "Composable TUI library for Guile")
    (description
     "Bubble-Tea-shaped TUI library for Guile. View functions return a tree of
view nodes; a renderer flattens that tree to draw commands; a pluggable backend
(ANSI today, future test/web) translates commands to bytes. Faces are symbolic
and resolved by the backend.  Keymap layer with multi-chord sequences.  Built
on guile-fibers.")
    (home-page "https://github.com/bretfhorne/guile-canary")
    (license l:gpl3+)))

guile-canary
