#lang racket/base
;; Per-binding keyed-relay rendezvous proof: the Racket binding cold-dials a
;; non-listening peer by its key designator through the reference relay's
;; rendezvous bridge (ADR-0088). The core classifies the locator as the
;; rendezvous dial shape; the binding opens the WebSocket leg the host's
;; configured mapping names and runs the keyed handshake end to end.
;;
;; Run via `zig build racket-keyed-relay-rendezvous` (the harness passes
;; `<relay-port> <designator>`).

(require "../../racket/pancake.rkt")

(define (fail msg)
  (eprintf "FAIL: ~a\n" msg)
  (exit 1))

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 2)
  (fail "usage: racket_client.rkt <relay-port> <designator>"))
;; The harness appends the two; a pinned -Dport flag may sit before them.
(define relay-port (vector-ref argv (- (vector-length argv) 2)))
(define designator (vector-ref argv (- (vector-length argv) 1)))

(define m (make-fresh-host))
(set-host-rendezvous-url!
 m
 (lambda (id) (format "ws://127.0.0.1:~a/relay?rendezvous=~a" relay-port id)))
(define conn (connect (format "ocapn://~a.keyed-relay" designator) #:host m))
(define greeter (session-fetch conn "greeter"))
(define reply (session-send conn greeter 'greet "racket"))
(unless (equal? reply "hello racket, cold-dialed by rendezvous")
  (fail (format "unexpected greeting: ~v" reply)))
(session-close! conn)
(displayln
 "PASS: the Racket binding cold-dialed a registered peer by rendezvous — the core classified the keyed-relay locator, the host's configured relay mapping opened the bridge, and the keyed session answered")
