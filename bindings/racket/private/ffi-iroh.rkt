#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_net_transport_iroh.
;;
;; The iroh companion library (`libpancake_net_transport_iroh`, ADR-0055) is optional — absent
;; unless built with cargo — so it loads lazily on first `iroh-fn` use, caching
;; the bound table and naming the build step when the library is absent. Nothing
;; here is public; `../pancake-iroh.rkt` is the ergonomic surface over it. The
;; readiness-event cstruct below is the layout gate for iroh's drain_ready
;; records; frame bytes themselves ride raw pointers through the companion ABI.
(require ffi/unsafe
         "ffi-shared.rkt"
         "layouts-gen.rkt"
         "lib-resolve.rkt")
(provide iroh-fn
         _PancakeIrohReadyEvent
         PancakeIrohReadyEvent-conn PancakeIrohReadyEvent-events
         make-PancakeIrohConfig
         IROH-EV-READABLE IROH-EV-WRITABLE IROH-EV-CLOSED IROH-EV-ACCEPT)

;; Readiness event bits (the header's PANCAKE_IROH_EV_*), carried by a
;; `drain_ready` record. A single record may carry several at once.
(define IROH-EV-READABLE 1)
(define IROH-EV-WRITABLE 2)
(define IROH-EV-CLOSED 4)
(define IROH-EV-ACCEPT 8)

;; One readiness record drained by `pancake_iroh_netlayer_drain_ready` — the
;; cstruct counterpart of the header's `PancakeIrohReadyEvent`. `conn` is #f
;; (NULL) for an accept record (claimed with `try-accept`) and otherwise the
;; ready connection's handle; `events` is the IROH-EV-* bitset. The loop drains
;; an array of these, so it is allocated 'atomic-interior like the other cstructs
;; C writes into.
(define-cstruct _PancakeIrohReadyEvent ([conn _pointer] [events _uint32])
  #:malloc-mode 'atomic-interior)

;; The layout gate, as in `ffi-shared.rkt`: the hand-mirrored ready-event
;; record is pinned at require time against `PANCAKE-IROH-READY-EVENT-SIZE`
;; (from `layouts-gen.rkt`) and the field layout hand-copied here (conn at 0,
;; events at 8, trailing pad to 16).
(pin-layout! '_PancakeIrohReadyEvent _PancakeIrohReadyEvent PANCAKE-IROH-READY-EVENT-SIZE '(pointer uint32))

;; One iroh endpoint's config, the cstruct counterpart of the header's
;; PancakeIrohConfig: reachability (mandatory) + connect_timeout_ms (0 = the
;; built-in default). `make-PancakeIrohConfig` sets both fields explicitly, so
;; nothing rides on uninitialized memory (the zero-init contract).
(define-cstruct _PancakeIrohConfig ([reachability _uint32] [connect_timeout_ms _uint64])
  #:malloc-mode 'atomic-interior)
;; layout (reachability at 0, 4 pad, connect_timeout_ms at 8, 16 total).
(pin-layout! '_PancakeIrohConfig _PancakeIrohConfig PANCAKE-IROH-CONFIG-SIZE '(uint32 uint64))

(define iroh-ffi-cache (box #f))

;; Open the iroh ABI library and bind its symbols on first use, caching the
;; table. Optional, a clear error names the build step when it is absent.
(define (iroh-ffi)
  (or (unbox iroh-ffi-cache)
      (let ([table (load-iroh-ffi)])
        (set-box! iroh-ffi-cache table)
        table)))

(define (load-iroh-ffi)
  (define L
    (open-pancake-archive "pancake_net_transport_iroh"
     #:fail (lambda ()
              (error 'iroh
                     (string-append
                      "iroh transport unavailable: could not load libpancake_net_transport_iroh from "
                      "PANCAKE_LIB_DIR, the abi-versioned cache, zig-out/lib, or the system library path. "
                      "Build it with `zig build iroh-abi` (needs cargo).")))))
  (hasheq
   ;; The iroh archive keeps its own thread-local last-error slot, read through
   ;; `pancake_iroh_last_error` rather than the ocapn family's `pancake_last_error`.
   'last-error     (get-ffi-obj 'pancake_iroh_last_error L (_fun _pointer _size -> _size))
   'netlayer-new   (wrap-out1
                    (get-ffi-obj 'pancake_iroh_netlayer_new L
                      (_fun _pointer _size _PancakeIrohConfig-pointer _pointer -> _int32))
                    _pointer #f)
   'netlayer-close (get-ffi-obj 'pancake_iroh_netlayer_close L (_fun _pointer -> _void))
   'netlayer-release (get-ffi-obj 'pancake_iroh_netlayer_release L (_fun _pointer -> _void))
   'node-id        (wrap-out1
                    (get-ffi-obj 'pancake_iroh_netlayer_node_id L
                      (_fun _pointer _pointer _size _pointer -> _int32))
                    _size 0)
   'direct-addrs   (wrap-out1
                    (get-ffi-obj 'pancake_iroh_netlayer_direct_addrs L
                      (_fun _pointer _pointer _size _pointer -> _int32))
                    _size 0)
   'conn-release   (get-ffi-obj 'pancake_iroh_conn_release L (_fun _pointer -> _void))
   ;; The event-driven loop surface (ADR-0057): the netlayer's one I/O model.
   ;; Park a green thread on the readiness fd (via `unsafe-file-descriptor->semaphore`),
   ;; drain records when it signals, and drive non-blocking byte I/O, one place
   ;; serves many connections. `readiness-fd` returns the fd; `drain-ready` drains
   ;; into a caller-owned array (read with `ptr-ref`, so a plain pointer). Only
   ;; `try-connect` (the dial blocks) is #:blocking?; everything else never parks.
   'readiness-fd   (get-ffi-obj 'pancake_iroh_netlayer_readiness_fd L (_fun _pointer -> _int32))
   'drain-ready    (wrap-out1
                    (get-ffi-obj 'pancake_iroh_netlayer_drain_ready L
                      (_fun _pointer _pointer _size _pointer -> _int32))
                    _size 0)
   'try-accept     (wrap-out1
                    (get-ffi-obj 'pancake_iroh_netlayer_try_accept L
                      (_fun _pointer _pointer -> _int32))
                    _pointer #f)
   'try-connect    (wrap-out1
                    (get-ffi-obj 'pancake_iroh_netlayer_try_connect L
                      (_fun #:blocking? #t _pointer _pointer _size _pointer _size _pointer -> _int32))
                    _pointer #f)
   'conn-try-read  (wrap-out1
                    (get-ffi-obj 'pancake_iroh_conn_try_read L
                      (_fun _pointer _pointer _size _pointer -> _int32))
                    _size 0)
   'conn-try-write (wrap-out1
                    (get-ffi-obj 'pancake_iroh_conn_try_write L
                      (_fun _pointer _pointer _size _pointer -> _int32))
                    _size 0)))

(define (iroh-fn key) (hash-ref (iroh-ffi) key))
