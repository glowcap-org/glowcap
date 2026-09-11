#lang racket/base
;; Public iroh composition over the raw readiness/runtime machinery.
;;
;; This module chooses how an application installs the iroh provider or
;; connector and how a driver-owned server is assembled. The sibling
;; `runtime.rkt` owns the resident, readiness loop, and raw byte endpoint.

(require racket/lazy-require
         "../constants.rkt"
         "../host.rkt"
         "../host/state.rkt"
         "../listen-loop.rkt"
         "../locator.rkt"
         "../seam.rkt"
         "../transport.rkt"
         "runtime.rkt")

(lazy-require
 ["../loop.rkt"
  (loop-listener-locator
   loop-server-locator
   loop-server-host
   loop-server-accept
   loop-server-close!)])

(provide iroh-locator iroh-provider iroh-connector listen-iroh
         iroh-server-locator iroh-server-uri iroh-server-node-id
         iroh-server-direct-addresses iroh-server-host
         iroh-server-accept iroh-server-close!)

;; Reachability is required on every public constructor; the binding never
;; guesses whether a peer expects direct, discovery, or relay-assisted reach.
(define (iroh-locator node-id [direct-addresses #f])
  (locator TRANSPORT-IROH node-id
           (if direct-addresses
               (hash HINT-DIRECT-ADDRESSES direct-addresses)
               (hash))
           (if direct-addresses 'map 'boolean-false)))

(define (iroh-provider config)
  (unless (iroh-config? config)
    (raise-argument-error 'iroh-provider "iroh-config?" config))
  (make-driver-provider
   (lambda (lp host)
     (iroh-adopt-loop! lp config #:seed (and host (host-seed host))))))

(define (iroh-connector config)
  (unless (iroh-config? config)
    (raise-argument-error 'iroh-connector "iroh-config?" config))
  (make-byte-connector
   (list TRANSPORT-IROH)
   (lambda (m loc handshake-timeout-ms)
     (define-values (transport proof)
       (dial-byte-transport
        (locator-designator loc)
        (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES "")
        (iroh-config-reachability config)))
     (establish-dialed-locator-session
      m loc transport
      #:verified-channel-key proof
      #:handshake-timeout-ms handshake-timeout-ms))))

;; A driver-owned keyed iroh server. The supplied Host is transferred into the
;; native loop; the binding does not implement a second CapTP admission path.
(struct iroh-server (node-id host loop-server))

;; The iroh designator derives from the durable seed, so the identity is
;; settled here before the listener opens and the shared spine opens the loop
;; with that same seed. `#:codec`, `#:captp-version`, `#:features`, and
;; `#:options` are the TCP listeners' keywords: each is honored exactly or
;; refused, and the iroh provider defines no per-listen options, so any value
;; other than an empty one is refused as the listener opens.
(define (listen-iroh config [seed #f] #:host [host #f]
                     #:codec [codec #f]
                     #:captp-version [captp-version #f]
                     #:features [features #f]
                     #:options [options #f])
  (unless (iroh-config? config)
    (raise-argument-error 'listen-iroh "iroh-config?" config))
  (define durable (listen-loop-identity 'listen-iroh #t seed host))
  (define node-id #f)
  (define server
    (listen-loop-profile 'listen-iroh TRANSPORT-IROH (designator-from-seed durable)
                         #:identity? #t
                         #:seed durable #:codec codec #:captp-version captp-version
                         #:features features #:options options
                         #:host host #:time-travel? #f
                         #:install (lambda (lp)
                                     (iroh-adopt-loop! lp config #:seed durable))
                         #:after-ready
                         (lambda (lp listener)
                           (set! node-id
                                 (locator-designator
                                  (loop-listener-locator lp listener))))))
  (iroh-server node-id (loop-server-host server) server))

(define (iroh-server-direct-addresses server)
  (define loc (loop-server-locator (iroh-server-loop-server server)))
  (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES ""))

(define (iroh-server-locator server)
  (loop-server-locator (iroh-server-loop-server server)))

(define (iroh-server-uri server)
  (format-locator-uri (iroh-server-locator server)))

(define (iroh-server-accept server)
  (loop-server-accept (iroh-server-loop-server server)))

(define (iroh-server-close! server)
  (loop-server-close! (iroh-server-loop-server server)))
