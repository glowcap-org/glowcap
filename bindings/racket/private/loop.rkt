#lang racket/base
;; Internal facade for the native driver loop. Implementation ownership lives
;; under loop/: core drives state/events, dial constructs Sessions, listeners
;; own admission/server lifetime, and lifecycle installs the Host close hooks.

(require ffi/unsafe
         racket/random
         "constants.rkt"
         "ffi-driver.rkt"
         "errors.rkt"
         "async.rkt"
         "abi-value.rkt"
         (combine-in "host.rkt" "host/state.rkt")
         (combine-in "session.rkt" "session/state.rkt")
         "transport.rkt"
         "loop/core.rkt"
         "loop/dial.rkt"
         "loop/listeners.rkt"
         "loop/lifecycle.rkt")

;; Construct the aggregate only after every owner module (notably lifecycle's
;; Host hook installation) has loaded. Internal leaves expose transitions to
;; siblings; only this complete facade can mint a usable driver loop.
(define (fresh-event-buf)
  (make-GlowcapDriverEvent
   0 0 0 0 0 0 0 0 0 0 0 #f
   (make-GlowcapHostAction
    0 0 0 #f
    (make-GlowcapArgument 0 0 0 0.0 #f 0 (make-GlowcapReference 0) #f 0)
    #f 0 0)
   #f 0 #f 0))

;; Native adoption is the one ownership transaction. Every Racket owner is
;; allocated first; Host attachment publishes only after the C call succeeds.
(define (open-driver-loop #:seed [seed #f]
                          #:codec [codec DEFAULT-CODEC-SYMBOL]
                          #:captp-version [captp-version DEFAULT-CAPTP-VERSION-SYMBOL]
                          #:features [features DEFAULT-FEATURES-SYMBOL]
                          #:wire-buffer-bytes [wire-buffer-bytes DRIVER-DEFAULT-WIRE-BUFFER-BYTES]
                          #:max-pending-opens [max-pending-opens DRIVER-DEFAULT-MAX-PENDING-OPENS]
                          #:handshake-ms [handshake-ms DRIVER-DEFAULT-HANDSHAKE-MS]
                          #:listener-setup-ms [listener-setup-ms DRIVER-DEFAULT-LISTENER-SETUP-MS]
                          #:settle-ms [settle-ms DRIVER-DEFAULT-SETTLE-MS]
                          #:host [supplied-host #f])
  (when (and supplied-host (host-loop-of supplied-host))
    (raise-glowcap 'open-driver-loop ERR-INVALID-ARGUMENT
                   "the supplied Host already belongs to a driver loop"))
  (define durable
    (bytes->immutable-bytes
     (or seed (and supplied-host (host-seed supplied-host)) (crypto-random-bytes 32))))
  (when (and supplied-host seed (not (bytes=? seed (host-seed supplied-host))))
    (raise-glowcap 'open-driver-loop ERR-INVALID-ARGUMENT
                   "the supplied Host seed conflicts with the loop seed"))
  (define m
    (or supplied-host
        (make-host durable #:codec codec #:captp-version captp-version
                   #:features features)))
  (define lp
    (driver-loop #f m (fresh-event-buf)
                 (make-hash) (make-hash) (make-hash)
                 (box 'open) #f (make-semaphore 0) #f #f))
  (define options
    (make-GlowcapDriverOptions DRIVER-OPTIONS-ABI-VERSION (ctype-sizeof _GlowcapDriverOptions)
                               wire-buffer-bytes max-pending-opens
                               handshake-ms listener-setup-ms settle-ms))
  (define adopted? #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (define cleanup
                       (with-handlers ([(lambda (_) #t) values])
                         (cond
                           [adopted? (driver-loop-abort! lp)]
                           [(not supplied-host) (host-close! m)])
                         #f))
                     (raise (if cleanup (retain-cleanup-failure e cleanup) e)))])
    (parameterize-break #f
      (define-values (rc h)
        (glowcap_driver_take_host (host-ptr m) options))
      (check/driver rc)
      (set-driver-loop-handle! lp h)
      (set-box! (host-driver-loop m) lp)
      (set! adopted? #t))
    lp))

(define (driver-loop-abort! lp)
  (host-close! (driver-loop-host lp)))

(provide open-driver-loop
         driver-loop?
         driver-loop-host
         driver-loop-start!
         driver-loop-abort!
         loop-background-failed!
         driver-loop-add-provider!
         driver-loop-has-transport?
         loop-listen!
         loop-listener-ready!
         loop-listener-locator
         loop-listener-restoration-state
         loop-listener-advertise!
         loop-listener-select!
         loop-listener-close!
         loop-connect-session
         make-loop-server
         loop-server?
         loop-server-time-travel?
         loop-server-locator
         loop-server-advertise!
         loop-server-accept
         loop-server-close!
         loop-server-host)
