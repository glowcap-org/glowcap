#lang racket/base
;; The listener spine every driver-loop server shares. A transport module owns
;; how its provider installs and what its bound locator means; this module owns
;; everything between: the identity and Host profile the loop opens with,
;; whether the listener rides a supplied Host's loop or one of its own, the
;; rollback ladder when setup fails, and the ready, select, and server tail.
;; The TCP, relay, iroh, and onion listeners are the callers, so a knob one
;; listener honors is honored by every listener, and a knob that conflicts
;; with a supplied Host is refused by every listener.

(require racket/lazy-require
         racket/random
         "abi-value.rkt"
         "constants.rkt"
         "errors.rkt"
         "host/state.rkt")

(lazy-require
 ["loop.rkt"
  (open-driver-loop
   driver-loop-start!
   driver-loop-abort!
   loop-listen!
   loop-listener-ready!
   loop-listener-select!
   loop-listener-close!
   make-loop-server)])

(provide listen-loop-profile
         listen-loop-identity
         resolve-host-profile)

;; The Host profile a fresh loop mints its Host with: each of `codec`,
;; `captp-version`, and `features` is the explicit value, else the supplied
;; Host's, else the generated default. An explicit value that differs from a
;; supplied Host's is refused, never replaced. `connect-onion` resolves its
;; dial-side loop through the same rule.
(define (resolve-host-profile who shared-host codec captp-version features)
  (check-host-profile-conflicts who shared-host codec captp-version features)
  (values (or codec (and shared-host (host-codec shared-host))
              DEFAULT-CODEC-SYMBOL)
          (or captp-version (and shared-host (host-captp-version shared-host))
              DEFAULT-CAPTP-VERSION-SYMBOL)
          (or features (and shared-host (host-features shared-host))
              DEFAULT-FEATURES-SYMBOL)))

;; The durable seed the loop opens with. A profile whose designator is a key
;; keeps one: the caller's, else the supplied Host's, else fresh entropy drawn
;; here at the binding boundary. A profile whose designator is an address has
;; no identity to keep and hands the loop no seed. A caller's seed must be 32
;; bytes and, beside a supplied Host, must be that Host's own; the loop cannot
;; carry two identities, so a differing seed is refused rather than replaced.
(define (listen-loop-identity who identity? seed shared-host)
  (unless (or (not seed) (and (bytes? seed) (= (bytes-length seed) 32)))
    (raise-glowcap who ERR-INVALID-ARGUMENT "seed must be 32 bytes"))
  (when (and seed shared-host (not (bytes=? seed (host-seed shared-host))))
    (raise-glowcap who ERR-INVALID-ARGUMENT
                   "the seed conflicts with the supplied Host"))
  (and identity?
       (or seed (and shared-host (host-seed shared-host)) (crypto-random-bytes 32))))

;; Open a listener for `transport` at `designator` through the generic driver
;; loop and return its server.
;;
;; `install!` receives the loop and installs the transport's provider; it runs
;; before the listener opens and inside the rollback ladder. `after-ready`
;; receives the loop and the ready listener before the listener is selected,
;; for a transport that advertises a locator other than the one it bound or
;; reads listener state into its own server value.
;;
;; `codec`, `captp-version`, and `features` resolve through
;; `resolve-host-profile`. `options` is the transport operation options value
;; handed to the driver for this one listen; the provider decides what it
;; accepts. `time-travel?` is the server's local time-travel policy. A
;; transport whose designator derives from the seed calls
;; `listen-loop-identity` first and passes that seed back in; the derivation
;; is idempotent, so the loop still opens with exactly one identity.
;;
;; A supplied Host that already belongs to a loop lends that loop; otherwise the
;; loop is opened here, and a supplied Host is transferred into it. Setup
;; failure closes a listener that opened and aborts a loop nobody else owns,
;; retaining each cleanup consequence on the construction failure.
(define (listen-loop-profile who transport designator
                             #:identity? identity?
                             #:seed seed
                             #:codec codec
                             #:captp-version captp-version
                             #:features features
                             #:options options
                             #:host shared-host
                             #:time-travel? time-travel?
                             #:install install!
                             #:after-ready [after-ready void])
  (define durable (listen-loop-identity who identity? seed shared-host))
  (define-values (loop-codec loop-captp-version loop-features)
    (resolve-host-profile who shared-host codec captp-version features))
  (define-values (lp owns-loop?)
    (if (and shared-host (host-loop-of shared-host))
        (values (host-loop-of shared-host) #f)
        (values
         (open-driver-loop #:host shared-host #:seed durable
                           #:codec loop-codec
                           #:captp-version loop-captp-version
                           #:features loop-features)
         #t)))
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
    (install! lp)
    (set! listener (loop-listen! lp transport designator options))
    (driver-loop-start! lp)
    (set! listener (loop-listener-ready! listener))
    (after-ready lp listener)
    (loop-listener-select! lp listener)
    (define server (make-loop-server lp listener time-travel? (not shared-host)))
    (set! listener #f)
    server))

(module+ test
  (require rackunit)
  ;; An address-designated profile keeps no identity.
  (check-false (listen-loop-identity 'test #f #f #f))
  ;; A key-designated profile draws one when nobody supplies it.
  (define drawn (listen-loop-identity 'test #t #f #f))
  (check-equal? (bytes-length drawn) 32)
  ;; A supplied seed is used exactly.
  (define supplied (make-bytes 32 7))
  (check-eq? (listen-loop-identity 'test #t supplied #f) supplied)
  ;; A seed of the wrong length is refused for every profile, not silently
  ;; padded or replaced.
  (for ([identity? (in-list '(#t #f))])
    (define refusal
      (with-handlers ([exn:fail:glowcap? values])
        (listen-loop-identity 'test identity? (make-bytes 16 1) #f)))
    (check-true (exn:fail:glowcap? refusal))
    (check-equal? (exn:fail:glowcap-code refusal) ERR-INVALID-ARGUMENT)))
