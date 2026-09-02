#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libglowcap_net_transport_iroh.
;;
;; The iroh companion library (`libglowcap_net_transport_iroh`, ADR-0055) is optional — absent
;; unless built with cargo — so it loads lazily on first `iroh-fn` use, caching
;; the bound table and naming the build step when the library is absent. Nothing
;; here is public; `../glowcap-iroh.rkt` is the ergonomic surface over it. The
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
         _GlowcapIrohReadyEvent
         GlowcapIrohReadyEvent-subject GlowcapIrohReadyEvent-events
         make-GlowcapIrohConfig
         make-GlowcapTransportProvider
         IROH-EV-READABLE IROH-EV-WRITABLE IROH-EV-CLOSED IROH-EV-ACCEPT IROH-EV-CONNECT)

;; Readiness event bits (the header's GLOWCAP_IROH_EV_*), carried by a
;; `drain_ready` record. A single record may carry several at once.
;; The IROH-EV-* values come from the generated constants module
;; (`constants-gen.rkt`), so they cannot drift from the C ABI.

;; One readiness record drained by `glowcap_iroh_netlayer_drain_ready` — the
;; cstruct counterpart of the header's `GlowcapIrohReadyEvent`. `conn` is #f
;; (NULL) for an accept record (claimed with `netlayer-try-accept`) and
;; otherwise the ready connection's handle; `events` is the IROH-EV-* bitset.
;; The loop drains an array of these, so it is allocated 'atomic-interior like
;; the other cstructs C writes into.
(define-cstruct _GlowcapIrohReadyEvent ([subject _uintptr] [events _uint32])
  #:malloc-mode 'atomic-interior)

;; The layout gate, as in `ffi-shared.rkt`: the hand-mirrored ready-event
;; record is pinned at require time against the size and kind layout
;; `layouts-gen.rkt` reflects off the real Zig type. The layout is what
;; `ctype->layout` reports rather than the ctype a field is declared with, so
;; `_uintptr` reads back as `uint64` on a 64-bit target.
(pin-layout! '_GlowcapIrohReadyEvent _GlowcapIrohReadyEvent GLOWCAP-IROH-READY-EVENT-SIZE
             GLOWCAP-IROH-READY-EVENT-LAYOUT)

;; One iroh endpoint's config, the cstruct counterpart of the header's
;; GlowcapIrohConfig: reachability (mandatory), connect_timeout_ms, and
;; idle_timeout_ms, the last two 0 for the built-in default.
;; `make-GlowcapIrohConfig` sets every field explicitly, so nothing rides on
;; uninitialized memory (the zero-init contract).
;;
;; idle_timeout_ms bounds how long a connection survives with nothing arriving
;; on it, which decides how quickly a peer killed rather than closed stops
;; counting as connected: it sends nothing, and UDP has no equivalent of the FIN
;; a dying TCP process gets from the operating system.
(define-cstruct _GlowcapIrohConfig ([reachability _uint32]
                                    [connect_timeout_ms _uint64]
                                    [idle_timeout_ms _uint64]
                                    [worker_threads _uint32])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_GlowcapIrohConfig _GlowcapIrohConfig GLOWCAP-IROH-CONFIG-SIZE
             GLOWCAP-IROH-CONFIG-LAYOUT)

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
    (open-glowcap-archive "glowcap_net_transport_iroh"
     #:fail (lambda ()
              (error 'iroh
                     (string-append
                      "iroh transport unavailable: could not load libglowcap_net_transport_iroh from "
                      "GLOWCAP_LIB_DIR, the abi-versioned cache, zig-out/lib, or the system library path. "
                      "Build it with `zig build iroh-abi` (needs cargo).")))))
  (define table (iroh-ffi-table L _GlowcapIrohConfig-pointer))
  (require-archive-fingerprint! 'iroh (hash-ref table 'archive-fingerprint) IROH-ARCHIVE-FINGERPRINT)
  table)

(define (iroh-fn key) (hash-ref (iroh-ffi) key))
