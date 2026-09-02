#lang racket/base
;; Settled CapTP profile projection for one live Session.

(require "../constants.rkt"
         "../abi-value.rkt"
         "../ffi-host.rkt"
         "../errors.rkt"
         "../host/state.rkt"
         "state.rkt")

(provide (all-defined-out))

(struct settled-profile (captp-version codec features) #:transparent)

(define (session-profile c)
  (guard-retained 'session-profile c)
  (call-with-host (session-host c)
    (lambda ()
      (define-values (rc captp-version codec features)
        (glowcap_host_session_profile (session-ptr c)))
      (check/host rc)
      (unless (zero? (bitwise-and features (bitwise-not FEATURE-FULL)))
        (raise-glowcap 'session-profile ERR-INTERNAL
                       "glowcap ABI returned unknown session feature mask ~a"
                       features))
      (settled-profile
       (captp-version<-id captp-version 'session-profile)
       (codec<-id codec 'session-profile)
       features))))

(define (session-transport-name c)
  (guard-retained 'session-transport-name c)
  (call-with-host (session-host c)
    (lambda ()
      (define-values (rc ptr len)
        (glowcap_host_session_transport_name (session-ptr c)))
      (check/host rc)
      (define bytes (bytes<-c ptr len))
      (with-handlers ([exn:fail?
                       (lambda (_)
                         (raise-glowcap 'session-transport-name ERR-INTERNAL
                                        "glowcap ABI returned a non-UTF-8 session transport name"))])
        (bytes->string/utf-8 bytes #f)))))
