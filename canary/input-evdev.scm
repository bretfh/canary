(define-module (canary input-evdev)
  #:use-module ((canary key) #:select (<key>))
  #:use-module (fibers)
  #:use-module ((fibers operations) #:select (perform-operation
                                              choice-operation))
  #:use-module ((fibers io-wakeup) #:select (wait-until-port-readable-operation))
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (oop goops)
  #:use-module (rnrs bytevectors)
  #:use-module ((srfi srfi-1) #:select (any filter-map iota))
  #:export (evdev-devices
            spawn-evdev-input!))

;;; Commentary:
;;;
;;; Kernel input events as a canary input source.  Reads
;;; /dev/input/eventN directly and translates EV_KEY events into the
;;; same <key> msgs the stdin escape parser produces, with real
;;; press / release / repeat fidelity on every device -- keyboards,
;;; gamepads, volume keys -- independent of what the hosting terminal
;;; forwards.  The terminal's keymap layer is bypassed: keycodes map
;;; through a fixed US base layer, so this source suits navigation,
;;; gaming, and device UIs rather than localized text entry (stdin
;;; stays the text-capable source).
;;;
;;; evdev has no focus semantics: events arrive whether or not the
;;; app's VT is active, and a keyboard on the active VT reaches the
;;; app twice -- once as stdin bytes, once as evdev events.  Scope
;;; the source with #:devices (name substrings or paths) to the
;;; devices stdin cannot see, e.g. '("Gamepad" "volume").
;;;
;;; Code:


;;;
;;; Keycode translation.
;;;

;; Modifier keycodes (input-event-codes.h) to canonical mod symbols.
(define %modifier-codes
  '((29  . control) (97  . control)
    (42  . shift)   (54  . shift)
    (56  . alt)     (100 . alt)
    (125 . super)   (126 . super)))

;; EV_KEY code to key sym.  A char is delivered as itself (upcased
;; under shift); a (base . shifted) pair picks by shift state; a
;; symbol is delivered as-is.  US base layer.
(define %key-syms
  '((1  . escape)
    (2  . (#\1 . #\!)) (3  . (#\2 . #\@)) (4  . (#\3 . #\#))
    (5  . (#\4 . #\$)) (6  . (#\5 . #\%)) (7  . (#\6 . #\^))
    (8  . (#\7 . #\&)) (9  . (#\8 . #\*)) (10 . (#\9 . #\())
    (11 . (#\0 . #\)))
    (12 . (#\- . #\_)) (13 . (#\= . #\+))
    (14 . backspace)   (15 . tab)
    (16 . #\q) (17 . #\w) (18 . #\e) (19 . #\r) (20 . #\t)
    (21 . #\y) (22 . #\u) (23 . #\i) (24 . #\o) (25 . #\p)
    (26 . (#\[ . #\{)) (27 . (#\] . #\}))
    (28 . enter)
    (30 . #\a) (31 . #\s) (32 . #\d) (33 . #\f) (34 . #\g)
    (35 . #\h) (36 . #\j) (37 . #\k) (38 . #\l)
    (39 . (#\; . #\:)) (40 . (#\' . #\")) (41 . (#\` . #\~))
    (43 . (#\\ . #\|))
    (44 . #\z) (45 . #\x) (46 . #\c) (47 . #\v) (48 . #\b)
    (49 . #\n) (50 . #\m)
    (51 . (#\, . #\<)) (52 . (#\. . #\>)) (53 . (#\/ . #\?))
    (57 . #\space)
    (59 . f1) (60 . f2) (61 . f3) (62 . f4)  (63 . f5)
    (64 . f6) (65 . f7) (66 . f8) (67 . f9)  (68 . f10)
    (87 . f11) (88 . f12)
    (102 . home) (103 . up)   (104 . pgup) (105 . left)
    (106 . right) (107 . end) (108 . down) (109 . pgdn)
    (110 . insert) (111 . delete)
    (114 . volume-down) (115 . volume-up) (116 . power)
    (304 . btn-south) (305 . btn-east) (307 . btn-north) (308 . btn-west)
    (310 . btn-tl)  (311 . btn-tr) (312 . btn-tl2) (313 . btn-tr2)
    (314 . btn-select) (315 . btn-start) (316 . btn-mode)
    (317 . btn-thumbl) (318 . btn-thumbr)
    (544 . dpad-up) (545 . dpad-down) (546 . dpad-left) (547 . dpad-right)))

(define (entry-sym entry shift?)
  "Resolve translation table ENTRY to the delivered key sym under
shift state SHIFT?."
  (match entry
    ((base . shifted) (if shift? shifted base))
    ((? char? c) (if (and shift? (char-alphabetic? c)) (char-upcase c) c))
    (sym sym)))


;;;
;;; Device discovery.
;;;

(define %event-limit 32)

(define (read-sysfs-line path)
  "Return the first line of PATH, or #f if unreadable."
  (catch #t
    (lambda ()
      (call-with-input-file path
        (lambda (port)
          (let ((line (read-line port)))
            (and (string? line) line)))))
    (lambda args args #f)))                               ;ignore

(define (device-name n)
  "Return the kernel-reported name of input device event N, or #f."
  (read-sysfs-line
   (format #f "/sys/class/input/event~a/device/name" n)))

(define (device-has-keys? n)
  "Return #t if input device event N reports any EV_KEY capability
(its sysfs key bitmap has a non-zero word)."
  (let ((caps (read-sysfs-line
               (format #f "/sys/class/input/event~a/device/capabilities/key" n))))
    (and caps
         (string-any (lambda (c) (not (memv c '(#\0 #\space)))) caps))))

(define* (evdev-devices #:optional (spec #t))
  "Return the /dev/input/eventN paths matching SPEC.  #t selects
every device with EV_KEY capability; a list selects by entry, each
either an explicit \"/dev/...\" path or a case-insensitive substring
of the kernel device name (e.g. \"Gamepad\")."
  (filter-map
   (lambda (n)
     (let ((path (format #f "/dev/input/event~a" n))
           (name (device-name n)))
       (and name
            (file-exists? path)
            (match spec
              (#t (and (device-has-keys? n) path))
              ((wants ...)
               (and (any (lambda (want)
                           (if (string-prefix? "/" want)
                               (string=? want path)
                               (string-contains-ci name want)))
                         wants)
                    path))))))
   (iota %event-limit)))


;;;
;;; Event reading.
;;;

;; struct input_event on 64-bit userland: 16 bytes of timeval, then
;; u16 type, u16 code, s32 value.
(define %event-size 24)
(define %EV_KEY 1)

(define (open-event-port path)
  "Open PATH read-only and non-blocking as an unbuffered port."
  (let ((port (open path (logior O_RDONLY O_NONBLOCK))))
    (setvbuf port 'none)
    port))

(define (mod<? a b)
  "Order modifier symbols alphabetically, matching the canonical
order `key' produces so key=? and keymap lookups compare equal."
  (string<? (symbol->string a) (symbol->string b)))

(define* (spawn-evdev-input! deliver #:key (devices #t) (stop-port #f)
                             (running? (lambda () #t)))
  "Spawn one fiber per evdev device matching DEVICES (a spec for
`evdev-devices'), translating EV_KEY events into <key> msgs passed
to DELIVER (a procedure of one argument).  Modifier keys are
tracked, not delivered; every other mapped key arrives with the
held modifier set and event 'press, 'release, or 'repeat.  Fibers
exit when RUNNING? goes false, woken through STOP-PORT (a readable
port that stays readable once the owner shuts down, e.g. the
engine's stop bell) so shutdown doesn't wait for a final keypress.
Devices that fail to open (permissions) are skipped.  Returns the
list of paths actually spawned.  Must be called inside fibers."
  (define mods '())
  (define (mods-add! mod)
    (unless (memq mod mods)
      (set! mods (sort (cons mod mods) mod<?))))
  (define (mods-drop! mod)
    (set! mods (delq mod mods)))
  (define (event->msg code value)
    (let ((event (case value
                   ((0) 'release)
                   ((1) 'press)
                   ((2) 'repeat)
                   (else #f)))
          (mod (assv-ref %modifier-codes code)))
      (cond
       ((not event) #f)
       (mod
        (if (eq? event 'release) (mods-drop! mod) (mods-add! mod))
        #f)
       ((assv-ref %key-syms code)
        => (lambda (entry)
             (make <key>
               #:sym   (entry-sym entry (memq 'shift mods))
               #:mods  mods
               #:event event)))
       (else #f))))
  (define (deliver-event! bv)
    (let ((type  (bytevector-u16-native-ref bv 16))
          (code  (bytevector-u16-native-ref bv 18))
          (value (bytevector-s32-native-ref bv 20)))
      (when (= type %EV_KEY)
        (let ((msg (event->msg code value)))
          (when msg (deliver msg))))))
  (define (device-loop port)
    (let ((wait-data (wait-until-port-readable-operation port))
          (wait-stop (and stop-port
                          (wait-until-port-readable-operation stop-port))))
      (let loop ()
        (cond
         ((not (running?)) (close-port port))
         (else
          (perform-operation
           (if wait-stop (choice-operation wait-data wait-stop) wait-data))
          (cond
           ((not (running?)) (close-port port))
           (else
            (let ((bv (get-bytevector-n port %event-size)))
              (cond
               ((eof-object? bv) (close-port port))
               ((and (bytevector? bv)
                     (= %event-size (bytevector-length bv)))
                (deliver-event! bv)
                (loop))
               (else (loop)))))))))))
  (let ((paths (evdev-devices devices)))
    (filter-map
     (lambda (path)
       (let ((port (false-if-exception (open-event-port path))))
         (and port
              (begin
                (spawn-fiber (lambda () (device-loop port)))
                path))))
     paths)))
