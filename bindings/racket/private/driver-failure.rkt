#lang racket/base
;; One projection of the driver's event and deterministic barrier failures.
;; FFI code owns lifecycle policy; this leaf copies borrowed names and
;; carries the first counted consequence in Racket's existing typed exception.

(require ffi/unsafe
         "constants.rkt"
         "ffi-driver.rkt"
         "ffi-shared.rkt"
         "errors.rkt"
         "carrier-failure.rkt"
         "value.rkt")

(provide (all-defined-out))

;; Marks a refusal produced by the loop drive itself, separating it from a
;; per-session effect that the shared drain may safely classify and continue.
(struct exn:fail:loop-drive exn:fail:glowcap ())

(define (raise-loop-drive error)
  (raise
   (exn:fail:loop-drive
    (exn-message error)
    (exn-continuation-marks error)
    (exn:fail:glowcap-code error)
    (exn:fail:glowcap-abort error)
    (exn:fail:glowcap-carrier-failure error)
    (exn:fail:glowcap-secondary-code error)
    (exn:fail:glowcap-secondary-name error)
    (exn:fail:glowcap-secondary-count error))))

(struct driver-failure
  (primary-result primary-name secondary-result secondary-count secondary-name carrier-failure)
  #:transparent)

(define (driver-failure-text ptr len field)
  (cond
    [(zero? len) ""]
    [(not ptr)
     (raise-glowcap 'driver ERR-INTERNAL "returned null ~a with nonzero length" field)]
    [else
     (with-handlers ([exn:fail?
                      (lambda (_)
                        (raise-glowcap 'driver ERR-INTERNAL "returned non-UTF-8 ~a" field))])
       (bytes->string/utf-8 (bytes<-c ptr len)))]))

(define (driver-failure<-event ev)
  (driver-failure
   (GlowcapDriverEvent-primary-result ev)
   (driver-failure-text (GlowcapDriverEvent-primary-name ev)
                        (GlowcapDriverEvent-primary-name-len ev)
                        "primary failure name")
   (GlowcapDriverEvent-secondary-result ev)
   (GlowcapDriverEvent-secondary-count ev)
   (driver-failure-text (GlowcapDriverEvent-secondary-name ev)
                        (GlowcapDriverEvent-secondary-name-len ev)
                        "secondary failure name")
   (decode-carrier-failure
    (GlowcapDriverEvent-carrier-phase ev)
    (GlowcapDriverEvent-carrier-detail-flags ev)
    (GlowcapDriverEvent-carrier-verification-flags ev)
    (GlowcapDriverEvent-carrier-peer-alert ev)
    (GlowcapDriverEvent-carrier-engine-code ev))))

(define (driver-failure-exn who failure abort)
  (exn:fail:glowcap
   (string-append
    (format "~a failed" who)
    (if (string=? (driver-failure-primary-name failure) "")
        ""
        (format ": ~a" (driver-failure-primary-name failure)))
    (if abort
        (format " [~a~a: ~a]" (abort-info-domain abort)
                (if (abort-info-kind abort) (format " ~a" (abort-info-kind abort)) "")
                (abort-info-message abort))
        ""))
   (current-continuation-marks)
   (driver-failure-primary-result failure)
   abort
   (driver-failure-carrier-failure failure)
   (and (positive? (driver-failure-secondary-count failure))
        (driver-failure-secondary-result failure))
   (and (positive? (driver-failure-secondary-count failure))
        (driver-failure-secondary-name failure))
   (driver-failure-secondary-count failure)))

(define (fresh-driver-failure)
  (make-GlowcapDriverFailure
   DRIVER-FAILURE-ABI-VERSION (ctype-sizeof _GlowcapDriverFailure)
   OK OK 0 0 0 0 0 0 #f 0 #f 0))

;; Call one provider/install or release barrier. The returned code remains the
;; ownership-commit authority; `failure` is #f only for a consistent success.
(define (call/driver-failure who proc)
  (define raw (fresh-driver-failure))
  (define code (proc raw))
  (with-handlers ([exn:fail:glowcap? (lambda (error) (values code error))])
    (define failure
      (driver-failure
       (GlowcapDriverFailure-primary-result raw)
       (driver-failure-text (GlowcapDriverFailure-primary-name raw)
                            (GlowcapDriverFailure-primary-name-len raw)
                            "primary failure name")
       (GlowcapDriverFailure-secondary-result raw)
       (GlowcapDriverFailure-secondary-count raw)
       (driver-failure-text (GlowcapDriverFailure-secondary-name raw)
                            (GlowcapDriverFailure-secondary-name-len raw)
                            "secondary failure name")
       (decode-carrier-failure
        (GlowcapDriverFailure-carrier-phase raw)
        (GlowcapDriverFailure-carrier-detail-flags raw)
        (GlowcapDriverFailure-carrier-verification-flags raw)
        (GlowcapDriverFailure-carrier-peer-alert raw)
        (GlowcapDriverFailure-carrier-engine-code raw))))
    (cond
      [(= code OK)
       (if (equal? failure (driver-failure OK "" OK 0 "" #f))
           (values code #f)
           (values code
                   (exn:fail:glowcap
                    (format "~a returned success with failure data" who)
                    (current-continuation-marks) ERR-INTERNAL #f #f #f #f 0)))]
      [(or (not (= code (driver-failure-primary-result failure)))
           (string=? "" (driver-failure-primary-name failure)))
       (values code
               (exn:fail:glowcap
                (format "~a returned an inconsistent failure record" who)
                (current-continuation-marks) ERR-INTERNAL #f #f #f #f 0))]
      [(or (and (zero? (driver-failure-secondary-count failure))
                (or (not (= OK (driver-failure-secondary-result failure)))
                    (not (string=? "" (driver-failure-secondary-name failure)))))
           (and (positive? (driver-failure-secondary-count failure))
                (or (= OK (driver-failure-secondary-result failure))
                    (string=? "" (driver-failure-secondary-name failure)))))
       (values code
               (exn:fail:glowcap
                (format "~a returned an inconsistent secondary failure" who)
                (current-continuation-marks) ERR-INTERNAL #f #f #f #f 0))]
      [else (values code (driver-failure-exn who failure #f))])))

(define (close-driver-listener! handle listener)
  (define-values (code failure)
    (call/driver-failure
     'driver-listener-close
     (lambda (out) (glowcap_driver_listener_close handle listener out))))
  (when (= code WOULD-BLOCK) (set! failure #f))
  (when failure (raise failure))
  (not (= code WOULD-BLOCK)))

(module+ test
  (require rackunit)
  (define primary-bytes #"ProviderConfigurationConflict")
  (define secondary-bytes #"PackageReleaseFailed")
  (define primary (pin-immobile primary-bytes))
  (define secondary (pin-immobile secondary-bytes))
  (define-values (code failure)
    (call/driver-failure
     'install
     (lambda (out)
       (set-GlowcapDriverFailure-primary-result! out ERR-INVALID-ARGUMENT)
       (set-GlowcapDriverFailure-primary-name! out primary)
       (set-GlowcapDriverFailure-primary-name-len! out (bytes-length primary-bytes))
       (set-GlowcapDriverFailure-secondary-result! out ERR-IO)
       (set-GlowcapDriverFailure-secondary-count! out 3)
       (set-GlowcapDriverFailure-secondary-name! out secondary)
       (set-GlowcapDriverFailure-secondary-name-len! out (bytes-length secondary-bytes))
       (set-GlowcapDriverFailure-carrier-phase! out CARRIER-PHASE-SECURE-HANDSHAKE)
       (set-GlowcapDriverFailure-carrier-detail-flags!
        out (bitwise-ior CARRIER-DETAIL-PEER-ALERT CARRIER-DETAIL-ENGINE-CODE))
       (set-GlowcapDriverFailure-carrier-verification-flags! out #x21)
       (set-GlowcapDriverFailure-carrier-peer-alert! out 42)
       (set-GlowcapDriverFailure-carrier-engine-code! out (- #x2700))
       ERR-INVALID-ARGUMENT)))
  (check-equal? code ERR-INVALID-ARGUMENT)
  (check-equal? (exn:fail:glowcap-code failure) ERR-INVALID-ARGUMENT)
  (check-true (regexp-match? #rx"ProviderConfigurationConflict" (exn-message failure)))
  (check-equal? (exn:fail:glowcap-secondary-code failure) ERR-IO)
  (check-equal? (exn:fail:glowcap-secondary-name failure) "PackageReleaseFailed")
  (check-equal? (exn:fail:glowcap-secondary-count failure) 3)
  (check-equal? (carrier-failure-phase (exn:fail:glowcap-carrier-failure failure))
                'secure-handshake)
  (check-equal? (carrier-failure-peer-alert (exn:fail:glowcap-carrier-failure failure)) 42)
  (check-equal? (carrier-failure-engine-code (exn:fail:glowcap-carrier-failure failure)) (- #x2700)))
