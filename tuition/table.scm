;;; table.scm --- Table rendering

(define-module (tuition table)
  #:use-module (tuition style)
  #:use-module (tuition text)
  #:use-module (tuition borders)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-table
            table-add-row
            table-render
            table?
            <table>))

;;; Table record
(define-record-type <table>
  (%make-table headers rows border)
  table?
  (headers table-headers set-table-headers!)
  (rows table-rows set-table-rows!)
  (border table-border set-table-border!))

(define* (make-table #:key
                     (headers '())
                     (rows '())
                     (border #f))
  "Create a new table"
  (%make-table headers rows (or border border-normal)))

(define (table-add-row table row)
  "Add a row to table"
  (set-table-rows! table (append (table-rows table) (list row)))
  table)

(define (column-width col-data)
  "Calculate width of column"
  (apply max (map visible-length col-data)))

(define (calculate-widths table)
  "Calculate column widths for table"
  (let* ((headers (table-headers table))
         (rows (table-rows table))
         (all-data (cons headers rows))
         (num-cols (if (null? headers) 0 (length headers))))
    (map (lambda (i)
           (column-width (map (lambda (row) (list-ref row i)) all-data)))
         (iota num-cols))))

(define (pad-cell text width)
  "Pad text to width"
  (let ((len (visible-length text)))
    (if (>= len width)
        text
        (string-append text (make-string (- width len) #\space)))))

(define (render-row cells widths left right sep)
  "Render a single row"
  (string-append left " "
                (string-join
                 (map pad-cell cells widths)
                 (string-append " " sep " "))
                " " right))

(define (table-render table)
  "Render table to string"
  (let* ((border (table-border table))
         (headers (table-headers table))
         (rows (table-rows table))
         (widths (calculate-widths table))
         (total-width (+ (apply + widths)
                        (* 3 (1- (length widths)))
                        4))
         (top-line (string-append (border-tl border)
                                 (make-string (- total-width 2)
                                            (string-ref (border-top border) 0))
                                 (border-tr border)))
         (sep-line (string-append (border-left border)
                                 (make-string (- total-width 2)
                                            (string-ref (border-top border) 0))
                                 (border-right border)))
         (bottom-line (string-append (border-bl border)
                                    (make-string (- total-width 2)
                                               (string-ref (border-bottom border) 0))
                                    (border-br border)))
         (header-row (if (null? headers)
                        '()
                        (list (render-row headers widths
                                        (border-left border)
                                        (border-right border)
                                        (border-left border))
                             sep-line)))
         (data-rows (map (lambda (row)
                          (render-row row widths
                                    (border-left border)
                                    (border-right border)
                                    (border-left border)))
                        rows)))
    (string-join (append (list top-line)
                        header-row
                        data-rows
                        (list bottom-line))
                nl)))
