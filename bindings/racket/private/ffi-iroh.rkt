#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_net_transport_iroh.
;;
;; The iroh companion library (`libpancake_net_transport_iroh`, ADR-0055) is optional — absent
;; unless built with cargo — so it loads lazily on first `iroh-fn` use, caching
;; the bound table and naming the build step when the library is absent. Nothing
;; here is public; `../pancake-iroh.rkt` is the ergonomic surface over it. The
;; readiness-event cstruct below is the layout gate for iroh's drain_ready
;; records; frame bytes themselves ride raw pointers through the companion ABI.
;; The keyed table itself is generated from the archive's annotated symbol
;; inventory (`ffi-iroh-gen.rkt`, `zig build gen-binding-racket-ffi`): this
;; module declares the cstructs and hands the opened library and the config
;; pointer type to the generated table builder.
(require ffi/unsafe
         "constants-gen.rkt"
         "ffi-iroh-gen.rkt"
         "ffi-shared.rkt"
         "layouts-gen.rkt"
         "lib-resolve.rkt")
(provide iroh-fn
         _PancakeIrohReadyEvent
         PancakeIrohReadyEvent-subject PancakeIrohReadyEvent-events
         make-PancakeIrohConfig
         IROH-EV-READABLE IROH-EV-WRITABLE IROH-EV-CLOSED IROH-EV-ACCEPT IROH-EV-CONNECT)

;; Readiness event bits (the header's PANCAKE_IROH_EV_*), carried by a
;; `drain_ready` record. A single record may carry several at once.
;; The IROH-EV-* values come from the generated constants module
;; (`constants-gen.rkt`), so they cannot drift from the C ABI.

;; One readiness record drained by `pancake_iroh_netlayer_drain_ready` — the
;; cstruct counterpart of the header's `PancakeIrohReadyEvent`. `conn` is #f
;; (NULL) for an accept record (claimed with `netlayer-try-accept`) and
;; otherwise the ready connection's handle; `events` is the IROH-EV-* bitset.
;; The loop drains an array of these, so it is allocated 'atomic-interior like
;; the other cstructs C writes into.
(define-cstruct _PancakeIrohReadyEvent ([subject _uintptr] [events _uint32])
  #:malloc-mode 'atomic-interior)

;; The layout gate, as in `ffi-shared.rkt`: the hand-mirrored ready-event
;; record is pinned at require time against `PANCAKE-IROH-READY-EVENT-SIZE`
;; (from `layouts-gen.rkt`) and the field layout hand-copied here (conn at 0,
;; events at 8, trailing pad to 16). The expected spelling is what
;; `ctype->layout` reports, not the ctype the field is declared with:
;; `_uintptr` is an alias that normalizes to `uint64` on a 64-bit target, and
;; naming the alias here fails the gate on every load.
(pin-layout! '_PancakeIrohReadyEvent _PancakeIrohReadyEvent PANCAKE-IROH-READY-EVENT-SIZE '(uint64 uint32))

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
  (iroh-ffi-table L _PancakeIrohConfig-pointer))

(define (iroh-fn key) (hash-ref (iroh-ffi) key))
