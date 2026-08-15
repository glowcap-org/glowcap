#lang racket/base
;; Native relay-provider composition for the generic driver loop.

(require net/url
         racket/lazy-require
         "constants.rkt"
         "ffi-driver.rkt"
         "ffi-relay.rkt"
         "ffi-shared.rkt"
         "errors.rkt"
         "locator.rkt"
         "loop.rkt"
         "host.rkt"
         "seam.rkt"
         "transport.rkt")

(lazy-require ["ws-transport.rkt" (ws-transport)])

(provide driver-loop-add-relay!
         relay-provider
         relay-connector
         keyed-relay-locator
         noise-relay-locator
         locator-relay-route
         relay-dial-url)

(define RENDEZVOUS-RELAY-HINT "rendezvous-relay")

(define (profile-locator transport designator relay-url)
  (locator transport designator
           (hash RENDEZVOUS-RELAY-HINT relay-url) 'map))

(define (keyed-relay-locator designator relay-url)
  (profile-locator TRANSPORT-KEYED-RELAY designator relay-url))

(define (noise-relay-locator designator relay-url)
  (profile-locator TRANSPORT-NOISE-RELAY designator relay-url))

(define (locator-relay-route loc)
  (define value (hash-ref (locator-hints loc) RENDEZVOUS-RELAY-HINT #f))
  (cond
    [(not value) #f]
    [(and (string? value) (positive? (string-length value))) value]
    [else
     (raise-pancake 'connect ERR-INVALID-ARGUMENT
                    "rendezvous-relay must be a non-empty string hint")]))

(define (relay-dial-url route designator)
  (define parsed (string->url route))
  (url->string
   (struct-copy url parsed
                [query (append (url-query parsed)
                               (list (cons 'rendezvous designator)))])))

(define (driver-loop-add-relay! lp relay-url [register-url ""])
  (define relay-bs (string->bytes/utf-8 relay-url))
    (define register-bs (string->bytes/utf-8 register-url))
    (define relay-ptr (pin-immobile relay-bs))
    (define register-ptr (and (positive? (bytes-length register-bs))
                              (pin-immobile register-bs)))
    (define config
      (make-PancakeRelayConfig relay-ptr (bytes-length relay-bs)
                               register-ptr (bytes-length register-bs)))
    (define-values (rc raw) (pancake_relay_runtime_new config))
    (check-with rc (lambda () (read-last-error pancake_relay_last_error)))
    (define package (make-PancakeTransportProvider 0 0 #f 0 #f #f #f #f))
    (with-handlers ([(lambda (_) #t)
                     (lambda (e)
                       (check-with (pancake_relay_runtime_release raw)
                                   (lambda () (read-last-error pancake_relay_last_error)))
                       (raise e))])
      (check-with (pancake_relay_transport_provider raw package)
                  (lambda () (read-last-error pancake_relay_last_error)))
      (driver-loop-add-provider! lp package)
      ;; Registration retained the package; release the constructor lease.
      (check-with (pancake_relay_runtime_release raw)
                  (lambda () (read-last-error pancake_relay_last_error)))))

(define (relay-provider #:relay-url relay-url
                        #:register-url [register-url ""])
  (make-driver-provider
   (lambda (lp _host)
     (driver-loop-add-relay! lp relay-url register-url))))

;; A WebSocket is a byte-transparent pipe and cannot claim noise-relay's
;; end-to-end sealing. The byte-fed connector therefore exposes keyed-relay
;; only; noise-relay requires the native provider above.
(define (relay-connector)
  (make-byte-connector
   (list TRANSPORT-KEYED-RELAY)
   (lambda (m loc handshake-timeout-ms)
     (define route (locator-relay-route loc))
     (unless route
       (raise-pancake 'relay-connector ERR-INVALID-ARGUMENT
                      "keyed-relay requires a rendezvous-relay hint"))
     (establish-dialed-locator-session
      m loc
      (ws-transport (relay-dial-url route (locator-designator loc)))
      #:handshake-timeout-ms handshake-timeout-ms))))
