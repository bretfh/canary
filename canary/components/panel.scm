(define-module (canary components panel)
  #:use-module (canary node)
  #:use-module (canary layout)
  #:use-module (canary borders)
  #:use-module (canary view)
  #:export (<panel-state>
            panel?
            make-panel
            panel-title
            panel-footer
            panel-border
            panel-face
            panel-hover-face
            panel-hover-border
            panel-content))

;; A panel is just a node. Its content slot accepts any node — there's
;; no widget vs view-tree distinction because everything is a node.
;; Hover: when hover-face is set, the rendered frame swaps to that face
;; (and to hover-border if supplied) while the cursor is inside.

(define-node panel
  #:state ((title #f)
           (footer #f)
           (border border-rounded)
           (face 'muted)
           (hover-face #f)
           (hover-border #f)
           (content #f))
  #:view
  (lambda (p)
    (let* ((base-face (panel-face p))
           (border    (panel-border p))
           (hf        (panel-hover-face p))
           (hb        (or (panel-hover-border p) border))
           (body      (let ((c (panel-content p)))
                        (cond
                         ((not c) (txt ""))
                         ((procedure? c) (c #f))
                         (else c))))
           (footer    (panel-footer p))
           (wrap-footer
            (lambda (face)
              (cond ((not footer) body)
                    (else (vbox body (txt footer #:fg face #:italic))))))
           (frame
            (lambda (face brd)
              (boxed (wrap-footer face)
                     #:border brd
                     #:fg     face
                     #:title  (panel-title p)))))
      (cond
       ((not hf) (frame base-face border))
       (else
        (on-hover (frame base-face border)
                  (lambda (_) (frame hf hb))))))))
