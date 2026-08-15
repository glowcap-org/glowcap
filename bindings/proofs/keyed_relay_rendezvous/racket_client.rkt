#lang racket/base
;; Per-binding keyed-relay rendezvous proof: the Racket binding cold-dials a
;; non-listening peer by its key designator through the reference relay's
;; rendezvous bridge (ADR-0088). The core classifies the locator as the
;; rendezvous dial shape; the binding opens the WebSocket leg the locator's
;; rendezvous-relay hint names, the one rendezvous routing authority.
;;
;; Run via `zig build racket-keyed-relay-rendezvous` (the harness passes
;; `<locator>`).

(require "../../racket/pancake.rkt"
         "../../racket/pancake-relay.rkt")

(define (fail msg)
  (eprintf "FAIL: ~a\n" msg)
  (exit 1))

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 1)
  (fail "usage: racket_client.rkt <locator>"))
(define locator (vector-ref argv (sub1 (vector-length argv))))

(define m (make-fresh-host))
(define runtime
  (open-runtime #:connectors (list (relay-connector)) #:adopt-host m))
(define session (runtime-connect runtime (parse-locator locator)))
(define greeter (session-fetch session "greeter"))
(define reply (session-send session greeter 'greet "racket"))
(unless (equal? reply "hello racket, cold-dialed by rendezvous")
  (fail (format "unexpected greeting: ~v" reply)))
(session-close! session)
(runtime-close! runtime)
(displayln
 "PASS: the Racket binding used the locator's rendezvous-relay route, and the keyed session answered")
