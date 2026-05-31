(use-modules (gnu packages commencement)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages version-control)
             (canary deps webui))

(packages->manifest
 (list guile-next
       guile-fibers
       webui
       gcc-toolchain
       gnu-make
       git))
