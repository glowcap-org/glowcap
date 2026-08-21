#lang racket/base
;; The native iroh endpoint and its fallible C-ABI operations. This module owns
;; the archive-specific handle, configuration, dial admission, and package
;; lease. The parent `iroh.rkt` owns readiness scheduling and application-facing
;; composition; it never duplicates these lifecycle rules.

(require racket/random
         "../constants.rkt"
         "../ffi-iroh.rkt"
         "../seam.rkt")

(provide (struct-out iroh-config)
         (struct-out iroh-netlayer)
         make-iroh-config
         check/iroh
         iroh-netlayer-new
         iroh-netlayer-node-id
         iroh-netlayer-direct-addresses
         iroh-netlayer-start-connect
         iroh-netlayer-finish-connect
         iroh-netlayer-cancel-connect
         iroh-loop-provider-parts
         iroh-netlayer-close/release!
         iroh-netlayer-release-construction!)

;; The diagnostic slot belongs to the iroh archive, not the core archive.
(define (iroh-last-error) (read-last-error (iroh-fn 'last-error)))
(define (check/iroh code) (check-with code iroh-last-error))

;; Nulling the handle before release makes explicit close and finalizer fallback
;; idempotent without a second lifecycle authority.
(struct iroh-netlayer (handle) #:mutable)

;; Reachability is mandatory. False timeout/worker values select the provider's
;; documented defaults and are projected as zero at the C boundary.
(struct iroh-config (reachability connect-timeout-ms idle-timeout-ms worker-threads)
  #:transparent)

(define (make-iroh-config reachability
                          #:connect-timeout-ms [connect-timeout-ms #f]
                          #:idle-timeout-ms [idle-timeout-ms #f]
                          #:worker-threads [worker-threads #f])
  (iroh-config reachability connect-timeout-ms idle-timeout-ms worker-threads))

(define (iroh-netlayer-new config [seed #f])
  (define seed* (or seed (crypto-random-bytes 32)))
  (define-values (rc handle)
    ((iroh-fn 'netlayer-new)
     (pin-immobile seed*)
     (bytes-length seed*)
     (make-PancakeIrohConfig
      (iroh-config-reachability config)
      (or (iroh-config-connect-timeout-ms config) 0)
      (or (iroh-config-idle-timeout-ms config) 0)
      (or (iroh-config-worker-threads config) 0))))
  (check/iroh rc)
  (values (iroh-netlayer handle) seed*))

(define (iroh-netlayer-node-id netlayer)
  (define buffer (make-bytes IROH-NODE-ID-BYTES))
  (define-values (rc len)
    ((iroh-fn 'netlayer-node-id) (iroh-netlayer-handle netlayer) buffer IROH-NODE-ID-BYTES))
  (check/iroh rc)
  (bytes->string/utf-8 (subbytes buffer 0 len)))

(define (iroh-netlayer-direct-addresses netlayer)
  (define-values (probe-rc probe-len)
    ((iroh-fn 'netlayer-direct-addrs)
     (iroh-netlayer-handle netlayer) #f 0))
  (define (read-direct-addresses capacity)
    (let loop ([capacity capacity])
      (define buffer (make-bytes capacity))
      (define-values (rc len)
        ((iroh-fn 'netlayer-direct-addrs)
         (iroh-netlayer-handle netlayer) buffer capacity))
      (cond
        [(and (= rc ERR-BUFFER-TOO-SMALL) (> len capacity))
         (loop len)]
        [else
         (check/iroh rc)
         (bytes->string/utf-8 (subbytes buffer 0 len))])))
  (cond
    [(= probe-rc ERR-BUFFER-TOO-SMALL)
     (read-direct-addresses probe-len)]
    [else
     (check/iroh probe-rc)
     (if (zero? probe-len)
         ""
         (read-direct-addresses probe-len))]))

;; Start parses its borrowed strings before return; finish owns the resulting
;; connection handle. Cancellation is an exact returned barrier, never a
;; fire-and-forget binding policy.
(define (iroh-netlayer-start-connect netlayer request-id node-id hints)
  (define node-bytes (string->bytes/utf-8 node-id))
  (define hint-bytes (string->bytes/utf-8 hints))
  (check/iroh
   ((iroh-fn 'netlayer-start-connect)
    (iroh-netlayer-handle netlayer)
    request-id
    (pin-immobile node-bytes)
    (bytes-length node-bytes)
    (pin-immobile hint-bytes)
    (bytes-length hint-bytes))))

(define (iroh-netlayer-finish-connect netlayer request-id)
  (define-values (rc conn)
    ((iroh-fn 'netlayer-finish-connect)
     (iroh-netlayer-handle netlayer) request-id))
  (check/iroh rc)
  conn)

(define (iroh-netlayer-cancel-connect netlayer request-id)
  (check/iroh
   ((iroh-fn 'netlayer-cancel-connect)
    (iroh-netlayer-handle netlayer) request-id)))

;; Construct one archive-owned provider package. The returned close procedure
;; remains the rollback owner until the generic driver adopts the package.
(define (iroh-loop-provider-parts config [seed #f])
  (define-values (netlayer _seed) (iroh-netlayer-new config seed))
  (define close! (lambda () (iroh-netlayer-close/release! netlayer)))
  (define package (make-PancakeTransportProvider 0 0 #f 0 #f #f #f #f))
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (close!)
                     (raise error))])
    (check/iroh
     ((iroh-fn 'transport-provider) (iroh-netlayer-handle netlayer) package)))
  (values netlayer package close!))

(define (iroh-netlayer-close/release! netlayer)
  (define handle (iroh-netlayer-handle netlayer))
  (when handle
    (set-iroh-netlayer-handle! netlayer #f)
    ((iroh-fn 'netlayer-close) handle)
    ((iroh-fn 'netlayer-release) handle)))

;; Successful provider registration retains its own package lease. Retiring the
;; constructor's occurrence must not shut that shared endpoint down.
(define (iroh-netlayer-release-construction! netlayer)
  (define handle (iroh-netlayer-handle netlayer))
  (when handle
    (set-iroh-netlayer-handle! netlayer #f)
    ((iroh-fn 'netlayer-release) handle)))
