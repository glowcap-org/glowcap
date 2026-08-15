#lang racket
;; Hermetic proof that a recipient's *configured redeem posture* governs how a
;; hint-less iroh handoff give is dialed (ADR-0009), all in the Racket binding —
;; the sibling of the Rust/Python `iroh_redeem_posture` clients.
;;
;; A give whose exporter location names the exporter by node id alone (no
;; `direct-addresses`) cannot be dialed DIRECT — the recipient must resolve the
;; id. Which discovery posture it resolves under is the recipient node's
;; `set-host-redeem-reachability!` knob: DISCOVERY (n0 relays + DNS/pkarr) by
;; default, lowerable for a deployment policy. This gate sets that knob to
;; LOCAL-DISCOVERY — an in-process address book, no network — and proves the
;; hint-less redeem dials by id through it and withdraws the gift.
;;
;; It is a *discriminating* proof: with the default DISCOVERY, the hint-less
;; redeem would reach for n0's public relays + DNS and fail with no internet; the
;; redeem succeeds here only because `dial-exporter` honors the configured
;; posture. Deterministic and flake-free — three LOCAL-DISCOVERY endpoints in one
;; process sharing one address book.
;;
;; Topology:
;;   Exporter  binds a LOCAL-DISCOVERY endpoint, publishes a node-giftable `greeter`.
;;   Gifter    binds its own endpoint, dials the exporter by id (one node
;;             identity), fetches the greeter, and records the exporter's id-only
;;             location as the give's exporter location — a hint-less give.
;;   Recipient binds its own endpoint, sets its redeem posture to LOCAL-DISCOVERY,
;;             dials the gifter, asks for the greeter, redeems the hint-less give
;;             by resolving the exporter's id through the book, and calls it.
;;
;; Needs `racket` plus the iroh ABI companion library (`zig build iroh-abi`); run
;; via `zig build racket-iroh-redeem-posture`.

(require "../../racket/pancake.rkt"
         "../../racket/pancake-iroh.rkt"
         "../../../interop/_common/racket/helpers.rkt")

(define NAME "racket-redeem-posture-carol")

(ignore-port-args "racket-iroh-redeem-posture")

;; Serve every connection a server accepts, each in its own green thread on the
;; one readiness loop; returns the accept thread. The accept loop ends when the
;; server closes (`iroh-server-accept` then raises).
(define (start-accept-loop s serves-box)
  (thread
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_) (void))])
       (let loop ()
         (define session (iroh-server-accept s))
         (set-box! serves-box (cons (thread (lambda () (session-serve session))) (unbox serves-box)))
         (loop))))))

;; ── Exporter: a node-giftable greeter on its own local-discovery endpoint ──────
(define exporter (listen-iroh (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)))
(host-publish-giftable (iroh-server-host exporter) "greeter"
                          (methods [(greet who) (format "hello ~a over a configured-posture redeem" who)]))
(define exporter-id (iroh-server-node-id exporter))
(define exporter-serves (box '()))
(define exporter-accept (start-accept-loop exporter exporter-serves))
(printf "racket-iroh-redeem-posture: exporter published greeter on ~a\n" exporter-id)

;; ── Gifter: dials the exporter by id, re-gifts the greeter under a hint-less give
(define gifter (listen-iroh (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)))
(define gifter-id (iroh-server-node-id gifter))
(define gifter-runtime
  (open-runtime
   #:providers (list (iroh-provider (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)))
   #:adopt-host (iroh-server-host gifter)))
(define to-exporter
  (runtime-connect gifter-runtime
                   (parse-locator (format-peer-uri TRANSPORT-IROH exporter-id))))
(define greeter-ref (session-fetch to-exporter "greeter"))
;; Record the exporter's location by node id alone, no direct-addresses. This is
;; what forces the recipient down the configured-posture redeem path.
(session-set-exporter-locator! to-exporter (locator "iroh" exporter-id (hash) 'map))
(host-publish-giftable (iroh-server-host gifter) "introducer"
                          (methods [(get-greeter) greeter-ref]))
(define gifter-serves (box '()))
(define gifter-accept (start-accept-loop gifter gifter-serves))
(printf "racket-iroh-redeem-posture: gifter published introducer on ~a\n" gifter-id)

;; ── Recipient: configures its redeem posture, then redeems the hint-less give ──
(define recipient-runtime
  (open-runtime
   #:providers (list (iroh-provider (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)))))
(with-handlers ([(lambda (_) #t)
                 (lambda (e)
                   (runtime-close! recipient-runtime)
                   (runtime-close! gifter-runtime)
                   (iroh-server-close! exporter)
                   (iroh-server-close! gifter)
                   (raise e))])
  (define recipient
    (runtime-connect recipient-runtime
                     (parse-locator (format-peer-uri TRANSPORT-IROH gifter-id))))
  ;; The knob under test: without it, the hint-less redeem defaults to DISCOVERY
  ;; (n0 relays + DNS) and would fail with no network.
  (set-host-redeem-reachability! (session-host recipient) IROH-REACH-LOCAL-DISCOVERY)
  (define introducer (session-fetch recipient "introducer"))
  (define greeter (session-send recipient introducer 'get-greeter))
  (unless (ref? greeter)
    (fail "racket-iroh-redeem-posture" (format "introduction did not redeem to a capability: ~a" greeter)))
  (printf "racket-iroh-redeem-posture: recipient redeemed the hint-less give under its configured LocalDiscovery posture, got the greeter as an ordinary ref\n")

  (define reply (session-send recipient greeter 'greet NAME))
  (unless (and (string? reply) (regexp-match? (regexp (regexp-quote NAME)) reply))
    (fail "racket-iroh-redeem-posture" (format "greeter reply did not carry the name back: ~a" reply)))
  (printf "racket-iroh-redeem-posture: greeter replied: ~a\n" reply)

  (printf (string-append
           "racket-iroh-redeem-posture OK: a hint-less iroh give was redeemed by id through the "
           "recipient's configured LocalDiscovery posture (default Discovery would need the network)\n"))

  ;; Teardown: close the dialing connections, then the servers, closing a server
  ;; stops its loop and raises out of the parked accept; the accepted connections
  ;; share that loop and netlayer, so their serve threads end on the EOF.
  (session-close! recipient)
  (session-close! to-exporter)
  (runtime-close! recipient-runtime)
  (runtime-close! gifter-runtime)
  (iroh-server-close! exporter)
  (iroh-server-close! gifter)
  (thread-wait exporter-accept)
  (thread-wait gifter-accept)
  (for ([t (append (unbox exporter-serves) (unbox gifter-serves))])
    (thread-wait t)))
