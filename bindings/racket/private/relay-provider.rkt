#lang racket/base
;; Native relay-provider composition for the generic driver loop.

(require net/url
         "constants.rkt"
         "ffi-driver.rkt"
         "ffi-relay.rkt"
         "ffi-shared.rkt"
         "errors.rkt"
         "locator.rkt"
         "loop.rkt")

(provide driver-loop-add-relay!
         locator-relay-route
         relay-dial-url)

(define RENDEZVOUS-RELAY-HINT "rendezvous-relay")

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
  (unless (driver-loop-has-transport? lp "keyed-relay")
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
    (define package (make-PancakeTransportProvider 0 0 #f 0 #f #f #f))
    (with-handlers ([(lambda (_) #t)
                     (lambda (e)
                       (pancake_relay_runtime_release raw)
                       (raise e))])
      (check-with (pancake_relay_transport_provider raw package)
                  (lambda () (read-last-error pancake_relay_last_error)))
      (driver-loop-add-provider! lp package)
      ;; Registration retained the package; release the constructor lease.
      (pancake_relay_runtime_release raw))))
