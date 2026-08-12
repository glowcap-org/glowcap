#lang racket
;; Live three-party handoff over iroh, all in the Racket binding (ADR-0009), the
;; Racket sibling of the Deno `zig build demo-rooms-dm-iroh` proof and the iroh
;; companion of `racket-goblins-handoff`. It proves both halves of an iroh handoff
;; through the binding's own surface: the gifter mints a `desc:handoff-give` whose
;; exporter location names an iroh endpoint by a `direct-addresses` dial hint, and
;; the recipient redeems it transparently by dialing that endpoint directly over
;; encrypted QUIC.
;;
;; Topology — three iroh endpoints (separate identities) in one process, the
;; relay-less DIRECT posture on loopback, so the gate is deterministic and
;; flake-free (no discovery service, no network):
;;   Exporter  binds an iroh endpoint and publishes a node-giftable `greeter`.
;;   Gifter    binds its own endpoint, dials the exporter (sharing one node
;;             identity), fetches the greeter, records the exporter's dialable URI
;;             as the give's exporter location, and publishes an `introducer` that
;;             returns the greeter.
;;   Recipient binds its own endpoint, dials the gifter, asks the introducer for
;;             the greeter, transparently redeems the give by dialing the exporter
;;             directly, and calls it — the reply must echo its name.
;;
;; Returning the exporter's greeter (home = gifter↔exporter) on the recipient's
;; connection trips the transparent gifter; the recipient's `session-send` resolves
;; to an ordinary capability whose calls route straight to the exporter. The proof
;; is the greeter's reply carrying the name the recipient sent.
;;
;; Needs `racket` plus the iroh ABI companion library (`zig build iroh-abi`); run
;; via `zig build racket-iroh-handoff`.

(require "../../bindings/racket/pancake.rkt"
         "../../bindings/racket/pancake-iroh.rkt"
         "../_common/racket/helpers.rkt")

(define NAME "racket-iroh-carol")

(ignore-port-args "racket-iroh-handoff")

;; An iroh endpoint reports its direct addresses asynchronously after bind; wait
;; for at least one before reading the dialable id+addresses, a give with no
;; direct-addresses hint is not dialable under the relay-less Direct posture.
(define (dialable s)
  (let loop ([n 0])
    (define addrs (iroh-server-direct-addresses s))
    (cond
      [(> (string-length addrs) 0) (values (iroh-server-node-id s) addrs)]
      [(>= n 1000) (fail "racket-iroh-handoff" "timed out waiting for an endpoint's direct addresses")]
      [else (sleep 0.02) (loop (add1 n))])))

;; Serve every session a server accepts, each in its own green thread on the
;; one readiness loop; returns the accept thread. The per-connection serve threads
;; are pushed to `serves-box` so teardown can join them, they end on their own
;; when the server closes (its netlayer release feeds each accepted connection a
;; clean EOF), so the accepted connections are never closed by hand (they share
;; the server's loop and netlayer). The accept loop ends when the server closes
;; and `iroh-server-accept` raises.
(define (start-accept-loop s serves-box)
  (thread
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_) (void))])
       (let loop ()
         (define session (iroh-server-accept s))
         (set-box! serves-box (cons (thread (lambda () (session-serve session))) (unbox serves-box)))
         (loop))))))

;; ── Exporter: a node-giftable greeter on its own endpoint ─────────────────────
(define exporter (listen-iroh (make-iroh-config IROH-REACH-DIRECT)))
(host-publish-giftable (iroh-server-host exporter) "greeter"
                          (methods [(greet who) (format "hello ~a over iroh handoff" who)]))
(define-values (exporter-id exporter-addrs) (dialable exporter))
(define exporter-serves (box '()))
(define exporter-accept (start-accept-loop exporter exporter-serves))
(printf "racket-iroh-handoff: exporter published greeter on ~a\n" exporter-id)

;; ── Gifter: dials the exporter under one identity, re-gifts the greeter ────────
(define gifter (listen-iroh (make-iroh-config IROH-REACH-DIRECT)))
(define-values (gifter-id gifter-addrs) (dialable gifter))
(define exporter-uri
  (format-peer-uri TRANSPORT-IROH exporter-id (hash HINT-DIRECT-ADDRESSES exporter-addrs)))
(define to-exporter
  (connect exporter-uri IROH-REACH-DIRECT #:host (iroh-server-host gifter)))
(define greeter-ref (session-fetch to-exporter "greeter"))
;; The exporter's own signed session record names it by node id alone — not
;; dialable under the relay-less Direct posture — so record its full dialable
;; location (id + direct-addresses) as the give's exporter location.
(session-set-exporter-locator!
 to-exporter
 (locator "iroh" exporter-id (hash HINT-DIRECT-ADDRESSES exporter-addrs) 'map))
(host-publish-giftable (iroh-server-host gifter) "introducer"
                          (methods [(get-greeter) greeter-ref]))
(define gifter-serves (box '()))
(define gifter-accept (start-accept-loop gifter gifter-serves))
(printf "racket-iroh-handoff: gifter published introducer on ~a\n" gifter-id)

;; ── Recipient: dials the gifter, redeems the give by dialing the exporter ──────
(with-handlers ([(lambda (_) #t)
                 (lambda (e)
                   (iroh-server-close! exporter)
                   (iroh-server-close! gifter)
                   (raise e))])
  (define gifter-uri
  (format-peer-uri TRANSPORT-IROH gifter-id (hash HINT-DIRECT-ADDRESSES gifter-addrs)))
(define recipient (connect gifter-uri IROH-REACH-DIRECT))
  (define introducer (session-fetch recipient "introducer"))
  (define greeter (session-send recipient introducer 'get-greeter))
  (unless (ref? greeter)
    (fail "racket-iroh-handoff" (format "introduction did not redeem to a capability: ~a" greeter)))
  (printf "racket-iroh-handoff: recipient redeemed the give, got the greeter as an ordinary ref\n")

  (define reply (session-send recipient greeter 'greet NAME))
  (unless (and (string? reply) (regexp-match? (regexp (regexp-quote NAME)) reply))
    (fail "racket-iroh-handoff" (format "greeter reply did not carry the name back: ~a" reply)))
  (printf "racket-iroh-handoff: greeter replied: ~a\n" reply)

  (printf (string-append
           "racket-iroh-handoff OK: the Racket binding minted an iroh handoff give and "
           "redeemed it by dialing the exporter directly over encrypted QUIC\n"))

  ;; Teardown: close the dialing connections (each owns its own netlayer), then
  ;; the servers, closing a server stops its loop, releases its netlayer (feeding
  ;; each accepted connection a clean EOF), and raises out of the parked accept.
  ;; The accepted connections share that loop and netlayer, so they are never
  ;; closed by hand; their serve threads end on the EOF and are joined here, so no
  ;; readiness thread outlives the endpoint it watches.
  (session-close! recipient)
  (session-close! to-exporter)
  (iroh-server-close! exporter)
  (iroh-server-close! gifter)
  (thread-wait exporter-accept)
  (thread-wait gifter-accept)
  (for ([t (append (unbox exporter-serves) (unbox gifter-serves))])
    (thread-wait t)))
