#lang racket
;; Live three-party handoff with the Racket binding as the recipient (Carol),
;; proving the binding redeems a `desc:handoff-give` transparently — through the
;; same `connect`/`conn-fetch`/`conn-send` application surface the demos use, with
;; no bespoke handoff choreography in the application. The binding counterpart of
;; `zig build goblins-handoff` (which proves it at the Zig driver level).
;;
;; It spawns the conformance Goblins introducer host (Alice on PORT, Bob the
;; exporter on PORT+1), learns Alice's introducer swiss-num from its NDJSON
;; readiness line, then:
;;   1. `connect` to Alice and `conn-fetch` the introducer.
;;   2. `(conn-send conn introducer 'get-greeter)`. Alice hands back Bob's greeter
;;      as a three-party handoff give. The connection's machine redeems it: it
;;      dials Bob directly (keyed with the *same* identity Alice saw), withdraws
;;      the gift, and resolves the send to an ordinary capability — the
;;      application never sees the give or the second connection.
;;   3. `(conn-send conn greeter (string->symbol "") "pancake-carol")`. The empty
;;      method is a positional (methodless) deliver, which the greeter lambda
;;      expects; the call routes straight to Bob and the reply carries the name
;;      back, proving data integrity end to end.
;;
;; Needs `racket` plus the `goblins` collection on PATH; run via
;; `zig build racket-goblins-handoff`.

(require "../../bindings/racket/pancake.rkt")

(define HOST "127.0.0.1")
;; Alice's port; Bob (the exporter) listens on PORT+1. --port=N (from
;; `zig build racket-goblins-handoff -Dport=N`) moves the pair when 22116 is taken.
(define PORT
  (let loop ([args (vector->list (current-command-line-arguments))])
    (cond
      [(null? args) 22116]
      [(regexp-match #px"^--port=(\\d+)$" (car args))
       => (lambda (m)
            (define p (string->number (cadr m)))
            (unless (<= 1 p 65534)
              (eprintf "racket-goblins-handoff: --port must be in 1..65534 (bob listens on port+1)\n")
              (exit 2))
            p)]
      [else
       (eprintf "racket-goblins-handoff: unknown argument ~a\n" (car args))
       (exit 2)])))
(define RACKET "/usr/local/bin/racket")
(define HOST-SCRIPT "conformance/goblins-peer/racket/handoff-introducer-host.rkt")

(define (fail msg)
  (eprintf "racket-goblins-handoff FAILED: ~a\n" msg)
  (exit 1))

(define (read-swiss port)
  (let loop ()
    (define line (read-line port))
    (cond
      [(eof-object? line) (fail "alice exited before publishing the introducer")]
      [(regexp-match #px"\"swiss\":\"([^\"]+)\"" line) => cadr]
      [else (loop)])))

(define-values (proc proc-out proc-in proc-err)
  (subprocess #f #f #f RACKET HOST-SCRIPT (number->string PORT) (number->string (+ PORT 1))))

(with-handlers ([(lambda (_) #t) (lambda (e) (subprocess-kill proc #t) (raise e))])
  (define swiss (read-swiss proc-out))
  (printf "racket-goblins-handoff: alice published introducer swiss=~a on ~a:~a\n" swiss HOST PORT)

  ;; `connect` completes the keyed handshake; the machine's retained identity is
  ;; the recipient key the gift Alice deposits will name.
  (define conn (connect (tcp-locator HOST PORT)))
  (printf "racket-goblins-handoff: session open (recipient -> alice)\n")

  (define introducer (conn-fetch conn swiss))
  (printf "racket-goblins-handoff: enlivened alice's introducer, asking for the greeter\n")

  ;; The introduction: Alice returns Bob's greeter as a handoff give. The binding
  ;; redeems it transparently, so this resolves to an ordinary capability.
  (define greeter (conn-send conn introducer 'get-greeter))
  (unless (or (far-ref? greeter) (near-ref? greeter))
    (fail (format "introduction did not redeem to a capability: ~a" greeter)))
  (printf "racket-goblins-handoff: introduction redeemed, got the greeter as an ordinary ref\n")

  ;; Call the greeter positionally (empty method). The send routes straight to Bob
  ;; (the exporter); the reply must echo the name we sent.
  (define reply (conn-send conn greeter (string->symbol "") "pancake-carol"))
  (unless (and (string? reply) (regexp-match? #rx"pancake-carol" reply))
    (fail (format "greeter reply did not carry the name back: ~a" reply)))
  (printf "racket-goblins-handoff: greeter replied: ~a\n" reply)

  (printf "racket-goblins-handoff OK: the Racket binding redeemed a three-party handoff from live Goblins and called the exporter directly\n")
  (connection-close! conn)
  (subprocess-kill proc #t))
