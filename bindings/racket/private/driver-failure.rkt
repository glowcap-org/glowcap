#lang racket/base
;; One projection of the driver's event and deterministic barrier failures.
;; Native code owns lifecycle policy; this leaf copies borrowed names and
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
(struct exn:fail:loop-drive exn:fail:pancake ())

(define (raise-loop-drive error)
  (raise
   (exn:fail:loop-drive
    (exn-message error)
    (exn-continuation-marks error)
    (exn:fail:pancake-code error)
    (exn:fail:pancake-abort error)
    (exn:fail:pancake-carrier-failure error)
    (exn:fail:pancake-secondary-code error)
    (exn:fail:pancake-secondary-name error)
    (exn:fail:pancake-secondary-count error))))

(struct driver-failure
  (primary-result primary-name secondary-result secondary-count secondary-name carrier-failure)
  #:transparent)

(define (driver-failure-text ptr len field)
  (cond
    [(zero? len) ""]
    [(not ptr)
     (raise-pancake 'driver ERR-INTERNAL "returned null ~a with nonzero length" field)]
    [else
     (with-handlers ([exn:fail?
                      (lambda (_)
                        (raise-pancake 'driver ERR-INTERNAL "returned non-UTF-8 ~a" field))])
       (bytes->string/utf-8 (bytes<-c ptr len)))]))

(define (driver-failure<-event ev)
  (driver-failure
   (PancakeDriverEvent-primary-result ev)
   (driver-failure-text (PancakeDriverEvent-primary-name ev)
                        (PancakeDriverEvent-primary-name-len ev)
                        "primary failure name")
   (PancakeDriverEvent-secondary-result ev)
   (PancakeDriverEvent-secondary-count ev)
   (driver-failure-text (PancakeDriverEvent-secondary-name ev)
                        (PancakeDriverEvent-secondary-name-len ev)
                        "secondary failure name")
   (decode-carrier-failure
    (PancakeDriverEvent-carrier-phase ev)
    (PancakeDriverEvent-carrier-detail-flags ev)
    (PancakeDriverEvent-carrier-verification-flags ev)
    (PancakeDriverEvent-carrier-peer-alert ev)
    (PancakeDriverEvent-carrier-engine-code ev))))

(define (driver-failure-exn who failure abort)
  (exn:fail:pancake
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
  (make-PancakeDriverFailure
   DRIVER-FAILURE-ABI-VERSION (ctype-sizeof _PancakeDriverFailure)
   OK OK 0 0 0 0 0 0 #f 0 #f 0))

;; Call one provider/install or release barrier. The returned code remains the
;; ownership-commit authority; `failure` is #f only for a consistent success.
(define (call/driver-failure who proc)
  (define raw (fresh-driver-failure))
  (define code (proc raw))
  (with-handlers ([exn:fail:pancake? (lambda (error) (values code error))])
    (define failure
      (driver-failure
       (PancakeDriverFailure-primary-result raw)
       (driver-failure-text (PancakeDriverFailure-primary-name raw)
                            (PancakeDriverFailure-primary-name-len raw)
                            "primary failure name")
       (PancakeDriverFailure-secondary-result raw)
       (PancakeDriverFailure-secondary-count raw)
       (driver-failure-text (PancakeDriverFailure-secondary-name raw)
                            (PancakeDriverFailure-secondary-name-len raw)
                            "secondary failure name")
       (decode-carrier-failure
        (PancakeDriverFailure-carrier-phase raw)
        (PancakeDriverFailure-carrier-detail-flags raw)
        (PancakeDriverFailure-carrier-verification-flags raw)
        (PancakeDriverFailure-carrier-peer-alert raw)
        (PancakeDriverFailure-carrier-engine-code raw))))
    (cond
      [(= code OK)
       (if (equal? failure (driver-failure OK "" OK 0 "" #f))
           (values code #f)
           (values code
                   (exn:fail:pancake
                    (format "~a returned success with failure data" who)
                    (current-continuation-marks) ERR-INTERNAL #f #f #f #f 0)))]
      [(or (not (= code (driver-failure-primary-result failure)))
           (string=? "" (driver-failure-primary-name failure)))
       (values code
               (exn:fail:pancake
                (format "~a returned an inconsistent failure record" who)
                (current-continuation-marks) ERR-INTERNAL #f #f #f #f 0))]
      [(or (and (zero? (driver-failure-secondary-count failure))
                (or (not (= OK (driver-failure-secondary-result failure)))
                    (not (string=? "" (driver-failure-secondary-name failure)))))
           (and (positive? (driver-failure-secondary-count failure))
                (or (= OK (driver-failure-secondary-result failure))
                    (string=? "" (driver-failure-secondary-name failure)))))
       (values code
               (exn:fail:pancake
                (format "~a returned an inconsistent secondary failure" who)
                (current-continuation-marks) ERR-INTERNAL #f #f #f #f 0))]
      [else (values code (driver-failure-exn who failure #f))])))

(define (close-driver-listener! handle listener)
  (define-values (code failure)
    (call/driver-failure
     'driver-listener-close
     (lambda (out) (pancake_driver_listener_close handle listener out))))
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
       (set-PancakeDriverFailure-primary-result! out ERR-INVALID-ARGUMENT)
       (set-PancakeDriverFailure-primary-name! out primary)
       (set-PancakeDriverFailure-primary-name-len! out (bytes-length primary-bytes))
       (set-PancakeDriverFailure-secondary-result! out ERR-IO)
       (set-PancakeDriverFailure-secondary-count! out 3)
       (set-PancakeDriverFailure-secondary-name! out secondary)
       (set-PancakeDriverFailure-secondary-name-len! out (bytes-length secondary-bytes))
       (set-PancakeDriverFailure-carrier-phase! out CARRIER-PHASE-SECURE-HANDSHAKE)
       (set-PancakeDriverFailure-carrier-detail-flags!
        out (bitwise-ior CARRIER-DETAIL-PEER-ALERT CARRIER-DETAIL-ENGINE-CODE))
       (set-PancakeDriverFailure-carrier-verification-flags! out #x21)
       (set-PancakeDriverFailure-carrier-peer-alert! out 42)
       (set-PancakeDriverFailure-carrier-engine-code! out (- #x2700))
       ERR-INVALID-ARGUMENT)))
  (check-equal? code ERR-INVALID-ARGUMENT)
  (check-equal? (exn:fail:pancake-code failure) ERR-INVALID-ARGUMENT)
  (check-true (regexp-match? #rx"ProviderConfigurationConflict" (exn-message failure)))
  (check-equal? (exn:fail:pancake-secondary-code failure) ERR-IO)
  (check-equal? (exn:fail:pancake-secondary-name failure) "PackageReleaseFailed")
  (check-equal? (exn:fail:pancake-secondary-count failure) 3)
  (check-equal? (carrier-failure-phase (exn:fail:pancake-carrier-failure failure))
                'secure-handshake)
  (check-equal? (carrier-failure-peer-alert (exn:fail:pancake-carrier-failure failure)) 42)
  (check-equal? (carrier-failure-engine-code (exn:fail:pancake-carrier-failure failure)) (- #x2700)))
