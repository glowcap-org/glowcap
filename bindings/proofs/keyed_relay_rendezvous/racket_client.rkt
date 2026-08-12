#lang racket/base
;; Per-binding keyed-relay rendezvous proof: the Racket binding cold-dials a
;; non-listening peer by its key designator through the reference relay's
;; rendezvous bridge (ADR-0088). The core classifies the locator as the
;; rendezvous dial shape; the binding opens the WebSocket leg the host's
;; locator names while the Host fallback is deliberately dead.
;;
;; Run via `zig build racket-keyed-relay-rendezvous` (the harness passes
;; `<locator>`).

(require "../../racket/pancake.rkt")

(define (fail msg)
  (eprintf "FAIL: ~a\n" msg)
  (exit 1))

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 1)
  (fail "usage: racket_client.rkt <locator>"))
(define locator (vector-ref argv (sub1 (vector-length argv))))

(define m (make-fresh-host))
(set-host-rendezvous-url!
 m
 (lambda (id) (format "ws://127.0.0.1:1/relay?rendezvous=~a" id)))
(define session (connect locator #:host m))
(define greeter (session-fetch session "greeter"))
(define reply (session-send session greeter 'greet "racket"))
(unless (equal? reply "hello racket, cold-dialed by rendezvous")
  (fail (format "unexpected greeting: ~v" reply)))
(session-close! session)
(displayln
 "PASS: the Racket binding used the locator's rendezvous-relay route instead of the dead Host fallback, and the keyed session answered")
