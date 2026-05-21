;;; spring.scm --- Spring physics for smooth animations
;;;
;;; Port of Ryan Juckett's damped harmonic oscillator
;;; https://www.ryanjuckett.com/damped-springs/

(define-module (canary spring)
  #:use-module (srfi srfi-9)
  #:export (make-spring-animation
            spring-update
            make-spring-smooth
            make-spring-bouncy
            make-spring-gentle
            make-spring-snappy
            fps))

(define epsilon 1.0e-8)

(define-record-type <spring>
  (%make-spring pos-pos-coef pos-vel-coef vel-pos-coef vel-vel-coef)
  spring?
  (pos-pos-coef spring-pos-pos-coef)
  (pos-vel-coef spring-pos-vel-coef)
  (vel-pos-coef spring-vel-pos-coef)
  (vel-vel-coef spring-vel-vel-coef))

(define (fps n)
  "Convert frames per second to time delta"
  (/ 1.0 (exact->inexact n)))

(define (make-spring-animation delta-time angular-frequency damping-ratio)
  "Create spring with precomputed coefficients.

   DELTA-TIME: Time step (use fps helper or provide seconds per frame)
   ANGULAR-FREQUENCY: Speed (higher = faster), typically 1.0-10.0
   DAMPING-RATIO: Oscillation behavior:
     < 1.0: Under-damped (bouncy, overshoots)
     = 1.0: Critically-damped (smooth, no overshoot)
     > 1.0: Over-damped (slow, no overshoot)"

  (let ((dt (exact->inexact delta-time))
        (omega (max 0.0 (exact->inexact angular-frequency)))
        (zeta (max 0.0 (exact->inexact damping-ratio))))

    ;; If angular frequency too small, return identity
    (if (< omega epsilon)
        (%make-spring 1.0 0.0 0.0 1.0)

        (cond
         ;; Over-damped (damping ratio > 1)
         ((> zeta (+ 1.0 epsilon))
          (let* ((za (* (- omega) zeta))
                 (zb (* omega (sqrt (- (* zeta zeta) 1.0))))
                 (z1 (- za zb))
                 (z2 (+ za zb))
                 (e1 (exp (* z1 dt)))
                 (e2 (exp (* z2 dt)))
                 (inv-two-zb (/ 1.0 (* 2.0 zb)))
                 (e1-over-two-zb (* e1 inv-two-zb))
                 (e2-over-two-zb (* e2 inv-two-zb))
                 (z1e1-over-two-zb (* z1 e1-over-two-zb))
                 (z2e2-over-two-zb (* z2 e2-over-two-zb)))

            (%make-spring
             (+ (- (* e1-over-two-zb z2) z2e2-over-two-zb) e2)
             (- e2-over-two-zb e1-over-two-zb)
             (* (+ (- z1e1-over-two-zb z2e2-over-two-zb) e2) z2)
             (- z2e2-over-two-zb z1e1-over-two-zb))))

         ;; Under-damped (damping ratio < 1)
         ((< zeta (- 1.0 epsilon))
          (let* ((omega-zeta (* omega zeta))
                 (alpha (* omega (sqrt (- 1.0 (* zeta zeta)))))
                 (exp-term (exp (* (- omega-zeta) dt)))
                 (cos-term (cos (* alpha dt)))
                 (sin-term (sin (* alpha dt)))
                 (inv-alpha (/ 1.0 alpha))
                 (exp-sin (* exp-term sin-term))
                 (exp-cos (* exp-term cos-term))
                 (exp-omega-zeta-sin-over-alpha (* exp-term omega-zeta sin-term inv-alpha)))

            (%make-spring
             (+ exp-cos exp-omega-zeta-sin-over-alpha)
             (* exp-sin inv-alpha)
             (- (* (- exp-sin) alpha) (* omega-zeta exp-omega-zeta-sin-over-alpha))
             (- exp-cos exp-omega-zeta-sin-over-alpha))))

         ;; Critically-damped (damping ratio = 1)
         (else
          (let* ((exp-term (exp (* (- omega) dt)))
                 (time-exp (* dt exp-term))
                 (time-exp-freq (* time-exp omega)))

            (%make-spring
             (+ time-exp-freq exp-term)
             time-exp
             (* (- omega) time-exp-freq)
             (+ (- time-exp-freq) exp-term))))))))

(define (spring-update spring position velocity target-position)
  "Update position and velocity toward target using spring physics.

   Returns (values new-position new-velocity)"

  (let* ((pos (exact->inexact position))
         (vel (exact->inexact velocity))
         (target (exact->inexact target-position))
         ;; Work in equilibrium-relative space
         (old-pos (- pos target))
         (old-vel vel)
         ;; Apply spring coefficients
         (new-pos (+ (* old-pos (spring-pos-pos-coef spring))
                     (* old-vel (spring-pos-vel-coef spring))
                     target))
         (new-vel (+ (* old-pos (spring-vel-pos-coef spring))
                     (* old-vel (spring-vel-vel-coef spring)))))

    (values new-pos new-vel)))

;;; Convenience presets

(define* (make-spring-smooth #:optional (frame-rate 60))
  "Smooth, critically-damped spring (no overshoot)"
  (make-spring-animation (fps frame-rate) 6.0 1.0))

(define* (make-spring-bouncy #:optional (frame-rate 60))
  "Bouncy, under-damped spring (overshoots)"
  (make-spring-animation (fps frame-rate) 6.0 0.5))

(define* (make-spring-gentle #:optional (frame-rate 60))
  "Gentle, over-damped spring (slow, no overshoot)"
  (make-spring-animation (fps frame-rate) 3.0 1.5))

(define* (make-spring-snappy #:optional (frame-rate 60))
  "Snappy, responsive spring"
  (make-spring-animation (fps frame-rate) 10.0 0.8))
