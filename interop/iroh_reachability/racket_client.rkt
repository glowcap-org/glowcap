#lang racket
;; Live real-internet iroh reachability proof in the Racket binding — the binding
;; sibling of the Zig `iroh-reachability` driver. Two iroh endpoints in one
;; process reach each other by node id ALONE over n0's public relays and DNS/pkarr
;; discovery: no direct-address hints, no in-process address book.
;;
;; Both endpoints bind with the DISCOVERY posture. The server publishes its node
;; info to pkarr on bind; the client dials the server by its 64-hex node id with
;; an empty hint set, so a session that opens proves the dial was resolved over
;; real discovery infrastructure and carried over a real relay / hole-punched
;; path — not hinted, not loopback-booked. The client's dial rides the
;; iroh provider's DISCOVERY retry that settles while the publish propagates.
;;
;; Not a hermetic gate. This step touches public n0 infrastructure
;; (`*.relay.iroh.network`, `dns.iroh.link`), and discovery-propagation timing
;; makes it unsuitable for `zig build check`. It runs only as the opt-in
;; `zig build racket-iroh-reachability`, the same posture as
;; `racket-iroh-loop`, so it can never make `check` flaky.
;;
;; Needs `racket` plus the iroh ABI companion library (`zig build iroh-abi`) and a
;; live internet connection; run via `zig build racket-iroh-reachability`.

(require "../../bindings/racket/glowcap.rkt"
         "../../bindings/racket/glowcap-iroh.rkt"
         "../_common/racket/helpers.rkt")

(define NAME "racket-iroh-world")

(ignore-port-args "racket-iroh-reachability")

;; Serve every session a server accepts, each in its own green thread on the
;; one readiness loop; returns the accept thread. The per-connection serve threads
;; are pushed to `serves-box` so teardown can join them, they end on their own
;; when the server closes (its netlayer release feeds each accepted connection a
;; clean EOF). The accept loop ends when the server closes and
;; `iroh-server-accept` raises.
(define (start-accept-loop s serves-box)
  (thread
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_) (void))])
       (let loop ()
         (define session (iroh-server-accept s))
         (set-box! serves-box (cons (thread (lambda () (session-serve session))) (unbox serves-box)))
         (loop))))))

;; ── Server: a giftable greeter, dialable by node id alone over discovery ───────
(define server (listen-iroh (make-iroh-config IROH-REACH-DISCOVERY)))
(host-publish-giftable (iroh-server-host server) "greeter"
                          (methods [(greet who) (format "hello ~a over iroh discovery" who)]))
(define server-id (iroh-server-node-id server))
(define server-serves (box '()))
(define server-accept (start-accept-loop server server-serves))
(printf "racket-iroh-reachability: server published greeter on ~a (pkarr-published; no direct addrs shared)\n"
        server-id)

;; ── Client: dial by node id ALONE — empty hints — over real n0 discovery ───────
(define client-runtime
  (open-runtime
   #:providers (list (iroh-provider (make-iroh-config IROH-REACH-DISCOVERY)))))
(with-handlers ([(lambda (_) #t)
                 (lambda (e)
                   (runtime-close! client-runtime)
                   (iroh-server-close! server)
                   (raise e))])
  (define client
    (runtime-connect client-runtime (iroh-locator server-id)))
  (printf "racket-iroh-reachability: client dialed by node id alone and opened the keyed session\n")

  (define greeter (session-fetch client "greeter"))
  (define reply (session-send client greeter 'greet NAME))
  (unless (and (string? reply) (regexp-match? (regexp (regexp-quote NAME)) reply))
    (fail "racket-iroh-reachability" (format "greeter reply did not carry the name back: ~a" reply)))
  (printf "racket-iroh-reachability: greeter replied: ~a\n" reply)

  (printf (string-append
           "racket-iroh-reachability OK: the Racket binding reached a peer by node id alone "
           "over n0 relays + DNS/pkarr discovery, no direct-address hints\n"))

  ;; Teardown: close the dialing connection (it owns its own netlayer), then the
  ;; server, closing the server stops its loop, releases its netlayer (feeding
  ;; each accepted connection a clean EOF), and raises out of the parked accept.
  ;; The accepted connections share that loop and netlayer, so they are never
  ;; closed by hand; their serve threads end on the EOF and are joined here.
  (session-close! client)
  (runtime-close! client-runtime)
  (iroh-server-close! server)
  (thread-wait server-accept)
  (for ([t (unbox server-serves)])
    (thread-wait t)))
