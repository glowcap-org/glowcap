#lang racket/base
;; TCP package composition for the native driver loop. The generic loop knows
;; only provider registration and transport occupancy; this module owns loading
;; the TCP archive and installing its complete profile package.

(require "ffi-driver.rkt"
         "ffi-tcp.rkt"
         "errors.rkt"
         "constants.rkt"
         "loop.rkt"
         "tcp-config.rkt"
         "tcp-channel.rkt"
         "locator.rkt"
         "seam.rkt"
         "transport.rkt")

(provide driver-loop-add-tcp!
         tcp-provider
         tcp-connector)

(define (driver-loop-add-tcp! lp [config #f])
  (define-values (rc tcp-handle)
    (pancake_tcp_netlayer_new
     (tcp-config->c (or config (make-tcp-config)))))
  (check-with rc (lambda () (read-last-error pancake_tcp_last_error)))
  (define package (make-PancakeTransportProvider 0 0 #f 0 #f #f #f #f))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (pancake_tcp_netlayer_release tcp-handle) (raise e))])
    (check-with (pancake_tcp_transport_provider tcp-handle package)
                (lambda () (read-last-error pancake_tcp_last_error)))
    (driver-loop-add-provider! lp package)
      ;; Registration retained the package; release the constructor's lease.
    (pancake_tcp_netlayer_release tcp-handle)))

;; One TCP archive owns the cleartext TCP profiles. Noise-TCP stays native-only
;; here: the byte-fed TCP socket has no Noise sealing layer and must not claim
;; that production transport symbol.
(define (tcp-provider [config (make-tcp-config)])
  (make-driver-provider
   (lambda (lp _host)
     (driver-loop-add-tcp! lp config))))

(define (tcp-connector)
  (make-byte-connector
   (list TRANSPORT-TCP TRANSPORT-KEYED-TCP)
   (lambda (m loc handshake-timeout-ms)
     (define address
       (if (string=? (locator-transport loc) TRANSPORT-TCP)
           (locator-designator loc)
           (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES
                     (lambda ()
                       (raise-pancake 'tcp-connector ERR-INVALID-ARGUMENT
                                      "keyed-tcp locator has no direct-addresses hint")))))
     (define-values (host port) (designator-host-port address))
     (establish-dialed-locator-session
      m loc
      (open-tcp-byte-transport host port)
      #:handshake-timeout-ms handshake-timeout-ms))))
