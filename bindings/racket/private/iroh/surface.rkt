#lang racket/base
;; Public iroh composition over the raw readiness/runtime machinery.
;;
;; This module chooses how an application installs the iroh provider or
;; connector and how a driver-owned server is assembled. The sibling
;; `runtime.rkt` owns the resident, readiness loop, and raw byte endpoint.

(require racket/lazy-require
         racket/random
         "../constants.rkt"
         "../errors.rkt"
         "../host.rkt"
         "../host/state.rkt"
         "../locator.rkt"
         "../seam.rkt"
         "../transport.rkt"
         "runtime.rkt")

(lazy-require
 ["../loop.rkt"
  (open-driver-loop
   driver-loop-start!
   driver-loop-abort!
   driver-loop-host
   loop-listen!
   loop-listener-ready!
   loop-listener-close!
   loop-listener-locator
   loop-listener-select!
   make-loop-server
   loop-server-locator
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

(define (listen-iroh config [seed #f] #:host [host #f])
  (define seed*
    (or seed (and host (host-seed host)) (crypto-random-bytes 32)))
  (unless (= (bytes-length seed*) 32)
    (raise-pancake 'listen-iroh ERR-INVALID-ARGUMENT
                   "the iroh seed must be 32 bytes"))
  (when (and host seed (not (bytes=? seed (host-seed host))))
    (raise-pancake 'listen-iroh ERR-INVALID-ARGUMENT
                   "the seed conflicts with the supplied Host"))
  (define-values (lp owns-loop?)
    (if (and host (host-loop-of host))
        (values (host-loop-of host) #f)
        (values (open-driver-loop #:host host #:seed seed*) #t)))
  (define listener #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (when listener (loop-listener-close! lp listener))
                     (when (and owns-loop? (not host)) (driver-loop-abort! lp))
                     (raise e))])
    (iroh-adopt-loop! lp config #:seed seed*)
    (set! listener
          (loop-listen! lp TRANSPORT-IROH (designator-from-seed seed*)))
    (driver-loop-start! lp)
    (set! listener (loop-listener-ready! listener))
    (define initial (loop-listener-locator lp listener))
    (define node-id (locator-designator initial))
    (loop-listener-select! lp listener)
    (iroh-server node-id (driver-loop-host lp)
                 (make-loop-server lp listener #f (not host)))))

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
