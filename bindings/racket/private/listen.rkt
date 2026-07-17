#lang racket/base
;; The listen / accept surface (binding spine Pass 3d): `server`,
;; `keyed-tcp-server`, and the top-level `listen` / `listen-keyed-tcp`
;; hosters. Session owns mint/handshake (`establish-accepted-session`); this
;; module owns the listening socket, accept loop, and self-designator bind.
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
  (establish-accepted-session)])

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
;; Each accepted partner gets its own session and vat. Pass port 0 for an
;; ephemeral port and read the bound one back with `server-port`. `accept`
;; takes `#:time-travel?`: pass #t to give the accepted session's vat a
;; retained, revisable behavior history (every actor it hosts), off by default.
;; The server carries one `host` (read it with `server-host`): every accepted
;; session shares its identity and gift registry, so a host-giftable
;; published on it with `host-publish-giftable` appears on each accepted
;; partner.
(struct server (listener host))

(define (listen host [port 0] #:codec [codec 'syrup])
  (define l (tcp-listen port 64 #t host))
  (define m (make-fresh-host #:codec codec))
  ;; This host also dials (the gifter side of a handoff), and its dials sign
  ;; the listener's own address so a partner's crossed-hellos table can
  ;; recognize it.
  (define-values (local-host local-port _rh _rp) (tcp-addresses l #t))
  (host-set-self-designator! m (socket-addr-designator local-host local-port))
  (server l m))

;; A keyed-tcp listening server: TCP sockets under a durable key designator
;; (ADR-0075). The host's Ed25519 identity *is* the locator designator and the
;; session signing key — one seed, not a second minted identity.
(struct keyed-tcp-server (listener host designator))

(define (listen-keyed-tcp host [port 0] #:seed [seed #f] #:codec [codec 'syrup])
  (define seed* (or seed (crypto-random-bytes 32)))
  (unless (= (bytes-length seed*) 32)
    (raise-pancake 'listen-keyed-tcp ERR-INVALID-ARGUMENT "seed must be 32 bytes"))
  (define designator (designator-from-seed seed*))
  (define m (make-host seed* #:codec codec))
  (define l (tcp-listen port 64 #t host))
  (host-set-self-designator! m designator)
  (keyed-tcp-server l m designator))

(define (keyed-tcp-server-port s)
  (define-values (_host port _rh _rp) (tcp-addresses (keyed-tcp-server-listener s) #t))
  port)

(define (keyed-tcp-server-uri s)
  (define-values (bound-host bound-port _rh _rp)
    (tcp-addresses (keyed-tcp-server-listener s) #t))
  (keyed-tcp-locator (keyed-tcp-server-designator s) bound-host bound-port))

(define (keyed-tcp-server-accept s #:time-travel? [time-travel? #f])
  (define-values (in out) (tcp-accept (keyed-tcp-server-listener s)))
  (define-values (local-host local-port _rh _rp) (tcp-addresses out #t))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (with-handlers ([(lambda (_) #t) void])
                       (close-output-port out)
                       (close-input-port in))
                     (raise e))])
    (establish-accepted-session (keyed-tcp-server-host s)
                                   TRANSPORT-KEYED-TCP
                                   (keyed-tcp-server-designator s)
                                   (port-transport in out)
                                   #:accepted-local-addr (socket-addr-designator local-host local-port)
                                   #:time-travel? time-travel?)))

(define (keyed-tcp-server-close! s) (tcp-close (keyed-tcp-server-listener s)))

(define (server-port s)
  (define-values (_host port _rh _rp) (tcp-addresses (server-listener s) #t))
  port)

(define (accept s #:time-travel? [time-travel? #f])
  (define-values (in out) (tcp-accept (server-listener s)))
  (define m (server-host s))
  (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
  (establish-accepted-session m TRANSPORT-TCP ""
                                 (port-transport in out)
                                 #:accepted-local-addr (socket-addr-designator local-host local-port)
                                 #:time-travel? time-travel?))

;; Stop accepting new partners. Connections already accepted are unaffected.
(define (server-close! s) (tcp-close (server-listener s)))
