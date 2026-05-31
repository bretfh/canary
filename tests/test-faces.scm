(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (srfi srfi-64)
             (gcell faces)
             (gcell backend-ansi))

(test-begin "faces")

(test-assert "default face lookup"
             (face? (face-table-lookup default-faces 'default)))

(test-assert "unknown face falls back to default"
             (face? (face-table-lookup default-faces 'no-such-face)))

(test-equal "accent face has fg"
            "#ff6b9d"
            (face-fg (face-table-lookup default-faces 'accent)))

(test-assert "face->sgr produces ANSI escape"
             (let ((s (face->sgr (face-table-lookup default-faces 'accent) '())))
               (and (string? s) (> (string-length s) 2))))

(test-end "faces")
