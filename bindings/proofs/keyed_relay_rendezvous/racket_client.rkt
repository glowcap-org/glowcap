#lang racket/base
;; Per-binding keyed-relay rendezvous proof: the Racket binding cold-dials a
;; non-listening peer by its key designator through the reference relay's
;; rendezvous bridge (ADR-0034). The core classifies the locator as the
;; rendezvous dial shape; the binding opens the WebSocket leg the locator's
;; rendezvous-relay hint names, the one rendezvous routing authority.
;;
;; Run via `zig build racket-keyed-relay-rendezvous` (the harness passes
;; `<locator>`).

(require racket/port
         racket/string
         "../../racket/glowcap.rkt"
         "../../racket/glowcap-relay.rkt")

(define (fail msg)
  (eprintf "FAIL: ~a\n" msg)
  (exit 1))

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 1)
  (fail "usage: racket_client.rkt <locator>"))
(define locator (vector-ref argv (sub1 (vector-length argv))))
(define partner (parse-locator locator))
(define wss-relay-url (getenv "GLOWCAP_PROOF_WSS_RELAY_URL"))
(define wss-ca-file (getenv "GLOWCAP_PROOF_WSS_RELAY_CA_FILE"))

(define (expect-wss-refusal route trust-pem cause)
  (define rt
    (open-runtime
     #:providers (list (relay-provider #:relay-url route #:trust-pem trust-pem))))
  (define refused
    (with-handlers ([exn:fail:glowcap? values])
      (define unexpected
        (runtime-connect rt (keyed-relay-locator (locator-designator partner) route)))
      (session-close! unexpected)
      #f))
  (runtime-close! rt)
  (unless refused
    (fail (format "WSS unexpectedly accepted ~a" cause)))
  (define carrier (exn:fail:glowcap-carrier-failure refused))
  (unless (and carrier
               (eq? (carrier-failure-phase carrier) 'secure-handshake)
               (positive? (carrier-failure-verification-flags carrier)))
    (fail (format "WSS omitted secure-handshake verification detail: ~a"
                  (exn-message refused))))
  (unless (string-contains? (exn-message refused) cause)
    (fail (format "WSS reported ~s, expected ~a"
                  (exn-message refused) cause))))

(define m (make-fresh-host))
(define composition
  (cond
    [(not wss-relay-url)
     (list 'connectors (list (relay-connector)))]
    [else
     (unless wss-ca-file
       (fail "WSS proof needs GLOWCAP_PROOF_WSS_RELAY_CA_FILE"))
     (define pem (call-with-input-file wss-ca-file port->bytes))
     (define wrong-host
       (string-replace wss-relay-url "//localhost:" "//127.0.0.1:"))
     (expect-wss-refusal wrong-host pem "CertificateNameMismatch")
     (expect-wss-refusal wss-relay-url #f "CertificateUntrusted")
     (list 'providers
           (list (relay-provider #:relay-url wss-relay-url #:trust-pem pem)))]))
(define runtime
  (if (eq? (car composition) 'providers)
      (open-runtime #:providers (cadr composition) #:adopt-host m)
      (open-runtime #:connectors (cadr composition) #:adopt-host m)))
(define session (runtime-connect runtime partner))
(define greeter (session-fetch session "greeter"))
(define reply (session-send session greeter 'greet "racket"))
(unless (equal? reply "hello racket, cold-dialed by rendezvous")
  (fail (format "unexpected greeting: ~v" reply)))
(session-close! session)
(runtime-close! runtime)
(displayln
 "PASS: the Racket binding used the locator's rendezvous-relay route, and the keyed session answered")
