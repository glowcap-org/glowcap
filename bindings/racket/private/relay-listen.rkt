#lang racket/base
;; Managed relay listeners over the generic driver loop: register a durable
;; key at the relay and accept sessions through the native driver. The
;; provider registers as the listener opens, so a ready listener means the
;; relay answered and holds this peer's sockets. The driver's provider
;; registry holds one relay configuration per loop: a second listen naming
;; the same routes rides the installed provider, and one naming different
;; routes is refused.

(require racket/lazy-require
         racket/random
         "constants.rkt"
         "errors.rkt"
         "host/state.rkt"
         "server-verbs.rkt")

(lazy-require
 ["loop.rkt"
  (open-driver-loop
   driver-loop-start!
   driver-loop-abort!
   loop-listen!
   loop-listener-ready!
   loop-listener-select!
   loop-listener-close!
   make-loop-server)]
 ["relay-provider.rkt" (driver-loop-add-relay!)])

(provide (all-from-out "server-verbs.rkt")
         listen-keyed-relay
         listen-noise-relay)

(define (listen-relay-profile who transport relay-url register-url seed shared-host trust-pem)
  (define seed*
    (or seed (and shared-host (host-seed shared-host)) (crypto-random-bytes 32)))
  (unless (= (bytes-length seed*) 32)
    (raise-pancake who ERR-INVALID-ARGUMENT "seed must be 32 bytes"))
  (when (and shared-host seed (not (bytes=? seed (host-seed shared-host))))
    (raise-pancake who ERR-INVALID-ARGUMENT
                   "the seed conflicts with the supplied Host"))
  (define-values (lp owns-loop?)
    (if (and shared-host (host-loop-of shared-host))
        (values (host-loop-of shared-host) #f)
        (values (open-driver-loop #:host shared-host #:seed seed*) #t)))
  (define listener #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (define failed-listener listener)
                     (raise-after-cleanups
                      e
                      (append
                       (if failed-listener
                           (list (lambda () (loop-listener-close! lp failed-listener)))
                           '())
                       (if (and owns-loop? (not shared-host))
                           (list (lambda () (driver-loop-abort! lp)))
                           '()))))])
    (driver-loop-add-relay! lp relay-url register-url #:trust-pem trust-pem)
    (set! listener (loop-listen! lp transport ""))
    (driver-loop-start! lp)
    (set! listener (loop-listener-ready! listener))
    (loop-listener-select! lp listener)
    (define server (make-loop-server lp listener #f (not shared-host)))
    (set! listener #f)
    server))

;; Register the identity-addressed cleartext relay profile. The locator is
;; still identity-addressed; the relay path is not sealed.
(define (listen-keyed-relay relay-url register-url
                            #:seed [seed #f] #:host [host #f]
                            #:trust-pem [trust-pem #f])
  (listen-relay-profile 'listen-keyed-relay TRANSPORT-KEYED-RELAY
                        relay-url register-url seed host trust-pem))

;; Register this listener's durable key at the relay and accept
;; Noise_XK-sealed sessions.
(define (listen-noise-relay relay-url register-url
                            #:seed [seed #f] #:host [host #f]
                            #:trust-pem [trust-pem #f])
  (listen-relay-profile 'listen-noise-relay TRANSPORT-NOISE-RELAY
                        relay-url register-url seed host trust-pem))
