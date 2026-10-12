#lang racket/base
;; Native relay-provider composition for the generic driver loop.

(require (only-in ffi/unsafe ctype-sizeof void/reference-sink)
         net/url
         racket/lazy-require
         racket/string
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
(define RENDEZVOUS-QUERY "rendezvous")
(define REGISTER-QUERY "id")
(define MAX-RENDEZVOUS-RELAY-HINT-BYTES RELAY-MAX-RENDEZVOUS-RELAY-HINT-BYTES)

(define (raise-invalid message)
  (raise-glowcap 'relay-route ERR-INVALID-ARGUMENT message))

(define (validate-designator designator)
  (unless (regexp-match? #px"^[0-9a-f]{64}$" designator)
    (raise-invalid "relay designator must be 64 lowercase hexadecimal characters")))

(define (validate-percent-encoding route)
  (let loop ([at 0])
    (when (< at (string-length route))
      (if (char=? #\% (string-ref route at))
          (begin
            (unless (and (< (+ at 2) (string-length route))
                         (regexp-match? #px"^[0-9a-fA-F]{2}$"
                                        (substring route (add1 at) (+ at 3))))
              (raise-invalid "rendezvous-relay carries malformed percent encoding"))
            (loop (+ at 3)))
          (loop (add1 at))))))

(define (valid-host? host)
  (cond
    [(regexp-match? #px":" host)
     (regexp-match? #px"^[0-9a-fA-F:.]+$" host)]
    [else
     (for/and ([label (in-list (string-split host "."))])
       (and (<= 1 (string-length label) 63)
            (regexp-match? #px"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"
                           label)))]))

(define (relay-route value)
  (unless (and (string? value) (positive? (string-length value)))
    (raise-invalid "rendezvous-relay must be a non-empty string hint"))
  (define encoded (string->bytes/utf-8 value))
  (when (> (bytes-length encoded) MAX-RENDEZVOUS-RELAY-HINT-BYTES)
    (raise-invalid
     (format "rendezvous-relay exceeds ~a UTF-8 bytes"
             MAX-RENDEZVOUS-RELAY-HINT-BYTES)))
  (unless (for/and ([byte (in-bytes encoded)]) (<= #x21 byte #x7e))
    (raise-invalid "rendezvous-relay must contain visible ASCII URI bytes"))
  (validate-percent-encoding value)
  (define parsed
    (with-handlers ([(lambda (_) #t)
                     (lambda (_) (raise-invalid
                                  "rendezvous-relay must be an absolute WebSocket URL"))])
      (string->url value)))
  (unless (and (member (url-scheme parsed) '("ws" "wss")) (url-host parsed))
    (raise-invalid "rendezvous-relay must use ws or wss"))
  (when (or (url-user parsed) (url-fragment parsed))
    (raise-invalid "rendezvous-relay cannot carry credentials or a fragment"))
  (when (equal? (url-port parsed) 0)
    (raise-invalid "rendezvous-relay carries an invalid port"))
  (unless (valid-host? (url-host parsed))
    (raise-invalid "rendezvous-relay carries an invalid host name"))
  (for ([field (in-list (url-query parsed))])
    (define name (symbol->string (car field)))
    (when (or (string=? name RENDEZVOUS-QUERY)
              (string=? name REGISTER-QUERY))
      (raise-invalid (format "rendezvous-relay reserves the ~a query parameter"
                             name))))
  value)

(define (profile-locator transport designator relay-url)
  (validate-designator designator)
  (locator transport designator
           (hash RENDEZVOUS-RELAY-HINT (relay-route relay-url)) 'map))

(define (keyed-relay-locator designator relay-url)
  (profile-locator TRANSPORT-KEYED-RELAY designator relay-url))

(define (noise-relay-locator designator relay-url)
  (profile-locator TRANSPORT-NOISE-RELAY designator relay-url))

(define (locator-relay-route loc)
  (define value (hash-ref (locator-hints loc) RENDEZVOUS-RELAY-HINT #f))
  (cond
    [(not value) #f]
    [else (relay-route value)]))

(define (relay-dial-url route designator)
  (validate-designator designator)
  (define admitted (relay-route route))
  (string-append admitted (if (string-contains? admitted "?") "&" "?")
                 RENDEZVOUS-QUERY "=" designator))

(define (driver-loop-add-relay! lp relay-url [register-url ""]
                                #:trust-pem [trust-pem #f]
                                #:relay-alias-url [relay-alias-url ""])
  (unless (or (not trust-pem) (bytes? trust-pem))
    (raise-argument-error 'driver-loop-add-relay! "(or/c #f bytes?)" trust-pem))
  (define relay-bs (string->bytes/utf-8 relay-url))
  (define register-bs (string->bytes/utf-8 register-url))
  (define alias-bs (string->bytes/utf-8 relay-alias-url))
  (define alias-ptr (and (positive? (bytes-length alias-bs))
                         (pin-immobile alias-bs)))
  (define relay-ptr (pin-immobile relay-bs))
  (define register-ptr (and (positive? (bytes-length register-bs))
                            (pin-immobile register-bs)))
  (define trust-ptr (and trust-pem
                         (positive? (bytes-length trust-pem))
                         (pin-immobile trust-pem)))
  (define config
    (make-GlowcapRelayConfig
     RELAY-CONFIG-ABI-VERSION (ctype-sizeof _GlowcapRelayConfig)
     relay-ptr (bytes-length relay-bs)
     register-ptr (bytes-length register-bs)
     (if trust-pem RELAY-TRUST-COPIED-PEM RELAY-TRUST-SYSTEM)
     trust-ptr (if trust-pem (bytes-length trust-pem) 0)
     alias-ptr (bytes-length alias-bs)))
  (define-values (rc raw) (glowcap_relay_runtime_new config))
  ;; The config cstruct is retained as the call's argument, but it carries
  ;; only the pins' raw addresses; the sink keeps the URL and PEM buffers
  ;; live for the whole constructor.
  (void/reference-sink relay-ptr register-ptr trust-ptr alias-ptr)
  (check-with rc (lambda () (read-last-error glowcap_relay_last_error)))
  (define package (make-GlowcapTransportProvider 0 0 #f 0 #f #f #f #f))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (define cleanup
                       (with-handlers ([(lambda (_) #t) values])
                         (check-with (glowcap_relay_runtime_release raw)
                                     (lambda () (read-last-error glowcap_relay_last_error)))
                         #f))
                     (raise (if cleanup
                                (retain-cleanup-failure e cleanup)
                                e)))])
    (check-with (glowcap_relay_transport_provider raw package)
                (lambda () (read-last-error glowcap_relay_last_error)))
    (driver-loop-add-provider! lp package)
    ;; Registration retained the package; release the constructor lease.
    (check-with (glowcap_relay_runtime_release raw)
                (lambda () (read-last-error glowcap_relay_last_error)))
    (void)))

(define (relay-provider #:relay-url relay-url
                        #:register-url [register-url ""]
                        #:trust-pem [trust-pem #f]
                        #:relay-alias-url [relay-alias-url ""])
  (make-driver-provider
   (lambda (lp _host)
     (driver-loop-add-relay! lp relay-url register-url #:trust-pem trust-pem
                            #:relay-alias-url relay-alias-url))))

;; A WebSocket is only the byte channel. The shared Host applies
;; noise-relay's end-to-end sealing after the channel is established.
(define (relay-connector)
  (make-byte-connector
   (list TRANSPORT-KEYED-RELAY TRANSPORT-NOISE-RELAY)
   (lambda (m loc handshake-timeout-ms)
     (define route (locator-relay-route loc))
     (unless route
       (raise-glowcap 'relay-connector ERR-INVALID-ARGUMENT
                      "relay connector requires a rendezvous-relay hint"))
     (establish-dialed-locator-session
      m loc
      (ws-transport (relay-dial-url route (locator-designator loc)))
      #:handshake-timeout-ms handshake-timeout-ms))))

(module+ test
  (require json
           racket/runtime-path
           rackunit)
  (define-runtime-path route-corpus-path "../../../test/net/fixtures/relay_routes.json")
  (define route-corpus (call-with-input-file route-corpus-path read-json))
  (define designator (hash-ref route-corpus 'designator))
  (define route "wss://Relay.Example.test/bridge?second=%2f&first=one")
  (check-equal? (relay-dial-url route designator)
                (string-append route "&rendezvous=" designator))
  (check-exn exn:fail?
             (lambda ()
               (relay-dial-url "wss://relay.example.test/" (make-string 64 #\A))))
  (for ([case (in-list (hash-ref route-corpus 'accepted))])
    (define route (hash-ref case 'route))
    (check-equal?
     (relay-dial-url route designator)
     (string-append route (if (string-contains? route "?") "&" "?")
                    RENDEZVOUS-QUERY "=" designator)))
  (for ([route (in-list (hash-ref route-corpus 'rejected))])
    (check-exn exn:fail? (lambda () (relay-dial-url route designator)))))
