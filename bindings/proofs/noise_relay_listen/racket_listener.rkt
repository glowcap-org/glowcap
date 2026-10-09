#lang racket/base
;; Per-binding noise-relay managed-listen proof, Racket half:
;; `listen-noise-relay` registers a fresh durable key at the reference relay
;; and serves accepted Noise_XK-sealed sessions. Run by `harness.ts`, which
;; appends `<relayUrl> <registerUrl>` and dials the printed locator.

(require racket/random
         "../../racket/glowcap.rkt"
         "../../racket/glowcap-relay.rkt")

(define args (vector->list (current-command-line-arguments)))
(when (< (length args) 2)
  (eprintf "usage: racket_listener.rkt <relayUrl> <registerUrl>\n")
  (exit 2))
(define relay-url (list-ref args (- (length args) 2)))
(define register-url (list-ref args (- (length args) 1)))

(define seed (crypto-random-bytes 32))
(define server (listen-noise-relay relay-url register-url #:seed seed))
(define host (server-host server))
(host-publish host "greeter"
  (methods [(greet who)
            (format "Hello, ~a" who)]))
(printf "RELAY-LISTENER-READY ~a\n" (server-uri server))
(flush-output)

(define session (accept server))
(dynamic-wind
 void
 (lambda () (session-serve session))
 (lambda ()
   (session-close! session)
   (server-close! server)))
