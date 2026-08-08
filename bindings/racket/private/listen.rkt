#lang racket/base
;; The listen / accept surface (binding spine Pass 3d): `server`,
;; `keyed-tcp-server`, and the top-level `listen` / `listen-keyed-tcp`
;; hosters. Session owns mint/handshake and the accept rule
;; (`accept-next-session`); this module owns the listening socket, how a
;; partner is claimed off it, and the self-designator bind.
;; iroh hosting lives in `pancake-iroh.rkt`, not here.
;;
;; Lazy-require breaks the session ↔ listen cycle: listen lazy-requires
;; session for establish; the public barrel (`pancake.rkt`) requires listen
;; directly.

(require racket/tcp
         racket/lazy-require
         racket/random
         "constants.rkt"
         "errors.rkt"
         "locator.rkt"
         "async.rkt"
         "host.rkt")

(lazy-require
 ["session.rkt"
  (accept-next-session)])

(provide (struct-out server)
         (struct-out keyed-tcp-server)
         listen
         listen-keyed-tcp
         server-port
         server-close!
         accept
         keyed-tcp-server-port
         keyed-tcp-server-uri
         keyed-tcp-server-accept
         keyed-tcp-server-close!)

;; ── Hosting: listen and accept ────────────────────────────────────────────────
;; The host side of the same surface. `listen` binds host:port and returns a
;; server; `accept` blocks for the next partner, completes the keyed OCapN
;; handshake (the exchange is symmetric, both ends send their op:start-session
;; first, then read), and returns a ready session exactly like `connect`.
;; A partner that fails that handshake — or that connects and then says
;; nothing past the handshake deadline — is skipped and `accept` waits for the
;; next one, so a rude probe never reaches the caller and never ends a
;; server's accept loop; `accept-next-session` in `private/session.rkt` owns
;; that rule for every listening surface. Only the listener's own failure (a
;; closed listener) raises.
;; Each accepted partner gets its own session and adapter-local Racket vat. Pass
;; port 0 for an ephemeral port and read the bound one back with `server-port`.
;; `accept` takes `#:time-travel?`: pass #t to retain a revisable history for
;; actors in that Racket vat, off by default. This is separate from the native
;; Host Vat, which owns the callback actors and survives Port closure. The server
;; carries one `host` (read it with `server-host`): every accepted session shares
;; its identity and live-session directory, and a host-giftable published with
;; `host-publish-giftable` is lazily discoverable through each accepted partner.
(struct server (listener host))

(define (listen host [port 0] #:codec [codec 'syrup] #:captp-version [captp-version 'v1_0]
                #:features [features 'full])
  (define l (tcp-listen port 64 #t host))
  (define m (make-fresh-host #:codec codec #:captp-version captp-version #:features features))
  ;; This host also dials (the gifter side of a handoff), and its dials sign
  ;; the listener's own address so a partner's crossed-hellos table can
  ;; recognize it.
  (define-values (local-host local-port _rh _rp) (tcp-addresses l #t))
  (define designator (socket-addr-designator local-host local-port))
  (host-set-self-designator! m designator)
  (host-set-advertised-locator! m (encode-peer-locator TRANSPORT-TCP designator))
  (server l m))

;; A keyed-tcp listening server: TCP sockets under a durable key designator
;; (ADR-0075). The host's Ed25519 identity *is* the locator designator and the
;; session signing key — one seed, not a second minted identity.
(struct keyed-tcp-server (listener host designator))

(define (listen-keyed-tcp host [port 0] #:seed [seed #f] #:codec [codec 'syrup]
                          #:captp-version [captp-version 'v1_0]
                          #:features [features 'full])
  (define seed* (or seed (crypto-random-bytes 32)))
  (unless (= (bytes-length seed*) 32)
    (raise-pancake 'listen-keyed-tcp ERR-INVALID-ARGUMENT "seed must be 32 bytes"))
  (define designator (designator-from-seed seed*))
  (define m (make-host seed* #:codec codec #:captp-version captp-version #:features features))
  (define l (tcp-listen port 64 #t host))
  (host-set-self-designator! m designator)
  (define-values (local-host local-port _rh _rp) (tcp-addresses l #t))
  (host-set-advertised-locator!
   m
   (encode-peer-locator TRANSPORT-KEYED-TCP designator
                        (socket-addr-designator local-host local-port)))
  (keyed-tcp-server l m designator))

(define (keyed-tcp-server-port s)
  (define-values (_host port _rh _rp) (tcp-addresses (keyed-tcp-server-listener s) #t))
  port)

(define (keyed-tcp-server-uri s)
  (define-values (bound-host bound-port _rh _rp)
    (tcp-addresses (keyed-tcp-server-listener s) #t))
  (keyed-tcp-locator (keyed-tcp-server-designator s) bound-host bound-port))

(define (keyed-tcp-server-accept s #:time-travel? [time-travel? #f])
  (accept-next-session (keyed-tcp-server-host s)
                          TRANSPORT-KEYED-TCP
                          (keyed-tcp-server-designator s)
                          (lambda ()
                            (define-values (in out) (tcp-accept (keyed-tcp-server-listener s)))
                            (define-values (local-host local-port _rh _rp) (tcp-addresses out #t))
                            ;; keyed-tcp names peers by key, but the socket
                            ;; proves none of it.
                            (values (port-transport in out)
                                    (socket-addr-designator local-host local-port)
                                    #f))
                          #:time-travel? time-travel?))

(define (keyed-tcp-server-close! s) (tcp-close (keyed-tcp-server-listener s)))

(define (server-port s)
  (define-values (_host port _rh _rp) (tcp-addresses (server-listener s) #t))
  port)

(define (accept s #:time-travel? [time-travel? #f])
  (accept-next-session (server-host s) TRANSPORT-TCP ""
                          (lambda ()
                            (define-values (in out) (tcp-accept (server-listener s)))
                            (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
                            ;; A socket proves nothing about who is on the
                            ;; other end.
                            (values (port-transport in out)
                                    (socket-addr-designator local-host local-port)
                                    #f))
                          #:time-travel? time-travel?))

;; Stop accepting new partners. Connections already accepted are unaffected.
(define (server-close! s) (tcp-close (server-listener s)))
