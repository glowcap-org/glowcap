#lang racket/base
;; Ergonomic TCP configuration shared by the direct netlayer and provider
;; composition surfaces. Raw C layouts remain in ffi-tcp-types.rkt.

(require "ffi-tcp-types.rkt"
         "layouts-gen.rkt"
         "transport.rkt")

(provide make-tcp-keepalive (struct-out tcp-keepalive)
         make-tcp-stream-options (struct-out tcp-stream-options)
         make-tcp-config (struct-out tcp-config)
         make-tcp-options
         tcp-stream-options->c tcp-config->c optional-tcp-stream-options->c)

(struct tcp-keepalive (idle-seconds interval-seconds count) #:transparent)
(struct tcp-stream-options (keepalive) #:transparent)
(struct tcp-config (stream) #:transparent)

(define (make-tcp-keepalive idle-seconds interval-seconds count)
  (tcp-keepalive idle-seconds interval-seconds count))

(define (make-tcp-stream-options #:keepalive [keepalive #f])
  (tcp-stream-options keepalive))

(define (make-tcp-config #:stream [stream (make-tcp-stream-options)])
  (tcp-config stream))

;; Provider configuration supplies defaults. This opaque value overrides them
;; for one runtime operation without exposing the generic driver's C envelope.
(define (make-tcp-options #:stream [stream (make-tcp-stream-options)])
  (define payload
    (make-PancakeTcpOperationOptions (tcp-stream-options->c stream)))
  (make-transport-operation-options payload
                                    PANCAKE-TCP-OPERATION-OPTIONS-SIZE))

(define (tcp-stream-options->c options)
  (define keepalive (tcp-stream-options-keepalive options))
  (if keepalive
      (make-PancakeTcpStreamOptions
       (tcp-keepalive-idle-seconds keepalive)
       (tcp-keepalive-interval-seconds keepalive)
       (tcp-keepalive-count keepalive))
      (make-PancakeTcpStreamOptions 0 0 0)))

(define (tcp-config->c config)
  (make-PancakeTcpConfig (tcp-stream-options->c (tcp-config-stream config))))

(define (optional-tcp-stream-options->c options)
  (and options (tcp-stream-options->c options)))
