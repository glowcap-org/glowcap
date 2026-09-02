#lang racket/base
;; Typed projection of the native carrier failure location.

(require "constants.rkt"
         "errors.rkt")

(provide (all-defined-out))

(struct carrier-failure
  (phase verification-flags peer-alert engine-code)
  #:transparent)

(define (decode-carrier-failure phase detail-flags verification-flags peer-alert engine-code)
  (cond
    [(= phase CARRIER-PHASE-NONE)
     (if (and (zero? detail-flags) (zero? verification-flags)
              (zero? peer-alert) (zero? engine-code))
         #f
         (raise-glowcap 'driver ERR-INTERNAL "returned carrier detail without a carrier phase"))]
    [else
     (define phase-name
       (cond [(= phase CARRIER-PHASE-RESOLVE) 'resolve]
             [(= phase CARRIER-PHASE-CONNECT) 'connect]
             [(= phase CARRIER-PHASE-SECURE-HANDSHAKE) 'secure-handshake]
             [(= phase CARRIER-PHASE-WEBSOCKET-UPGRADE) 'websocket-upgrade]
             [(= phase CARRIER-PHASE-REGISTRATION) 'registration]
             [(= phase CARRIER-PHASE-RECEIVE) 'receive]
             [(= phase CARRIER-PHASE-TRANSMIT) 'transmit]
             [(= phase CARRIER-PHASE-SHUTDOWN) 'shutdown]
             [else (raise-glowcap 'driver ERR-INTERNAL "returned unknown carrier phase ~a" phase)]))
     (define has-alert? (bitwise-bit-set? detail-flags 0))
     (define has-engine? (bitwise-bit-set? detail-flags 1))
     (define known (bitwise-ior CARRIER-DETAIL-PEER-ALERT CARRIER-DETAIL-ENGINE-CODE))
     (when (or (not (zero? (bitwise-and detail-flags (bitwise-not known))))
               (and (not has-alert?) (not (zero? peer-alert)))
               (and has-alert? (> peer-alert #xff))
               (and (not has-engine?) (not (zero? engine-code))))
       (raise-glowcap 'driver ERR-INTERNAL "returned inconsistent carrier failure detail"))
     (carrier-failure phase-name verification-flags
                      (and has-alert? peer-alert)
                      (and has-engine? engine-code))]))
