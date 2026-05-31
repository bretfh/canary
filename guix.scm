(use-modules (guix packages)
             (guix gexp)
             (guix git-download)
             (guix build-system gnu)
             ((guix licenses) #:prefix l:)
             (gnu packages commencement)
             (gnu packages guile)
             (gnu packages guile-xyz))

(define %gcell-checkout
  (dirname (current-filename)))

(define %gcell-source
  (local-file %gcell-checkout
              "guile-gcell-source"
              #:recursive? #t
              #:select? (git-predicate %gcell-checkout)))

(define-public guile-gcell
  (package
    (name "guile-gcell")
    (version "1.0.0")
    (source %gcell-source)
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
                          (find-files "gcell" "\\.scm$"))
                (copy-file "gcell.scm"
                           (string-append site "/gcell.scm"))
                (for-each (lambda (f)
                            (let* ((rel (substring f (string-length "build/")))
                                   (dst (string-append ccache "/" rel)))
                              (mkdir-p (dirname dst))
                              (copy-file f dst)))
                          (find-files "build" "\\.go$"))))))))
    (native-inputs (list guile-next gcc-toolchain))
    (inputs (list guile-next guile-fibers))
    (propagated-inputs (list guile-fibers))
    (synopsis "Live-reloadable TUI library for Guile")
    (description
     "Elm-shaped TUI library for Guile.  An app is a GOOPS class with two
generics: @code{view} returns a tree of nodes from state; @code{update} returns
the next state paired with an optional cmd.  Startup cmds, key handling, ticks
and resizes are all msgs dispatched through @code{update}; widgets compose by
embed-by-reference and the engine routes key/mouse msgs through a focus chain.  Layout
primitives (vbox, hbox, boxed, pad, align, width, height, flex, wrap, overlay,
pin, on-click, on-hover) are pure records.  Bundled widgets: button, panel,
textinput, spinner, progress, paginator, viewport.  A pluggable backend
translates draw cmds to bytes; the ANSI backend includes a cell-diff renderer,
kitty graphics, symbolic palette-resolved faces and a multi-chord keymap.
Subscriptions installed via (every #:id k ...) are cancellable.  Re-evaluating
a @code{define-method} or @code{define-class} updates the running process
without restart.  Built on guile-fibers.")
    (home-page "https://github.com/bretfhorne/guile-gcell")
    (license l:gpl3+)))

guile-gcell
