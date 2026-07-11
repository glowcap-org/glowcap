#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_net_transport_iroh.
;;
;; The iroh companion library (`libpancake_net_transport_iroh`, ADR-0055) is optional — absent
;; unless built with cargo — so it loads lazily on first `iroh-fn` use, caching
;; the bound table and naming the build step when the library is absent. Nothing
;; here is public; `../pancake-iroh.rkt` is the ergonomic surface over it. The
;; read/write calls move frames through the shared frame cstructs defined in
;; `ffi-shared.rkt`.
(require ffi/unsafe
         racket/runtime-path
         "ffi-shared.rkt")
(provide iroh-fn
         _PancakeIrohReadyEvent
         PancakeIrohReadyEvent-conn PancakeIrohReadyEvent-events
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
;; record is pinned at require time against the header's documented LP64
;; layout (conn at 0, events at 8, trailing pad to 16).
(pin-layout! '_PancakeIrohReadyEvent _PancakeIrohReadyEvent 16 '(pointer uint32))

(define-runtime-path iroh-lib-path "../../../zig-out/lib/libpancake_net_transport_iroh")
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
    (pancake-ffi-lib
     "pancake_net_transport_iroh" (path->string iroh-lib-path)
     #:fail (lambda ()
              (error 'iroh
                     (string-append
                      "iroh transport unavailable: could not load libpancake_net_transport_iroh from "
                      "PANCAKE_LIB_DIR, zig-out/lib, or the system library path. "
                      "Build it with `zig build iroh-abi` (needs cargo).")))))
  (hasheq
   ;; The iroh archive keeps its own thread-local last-error slot, read through
   ;; `pancake_iroh_last_error` rather than the ocapn family's `pancake_last_error`.
   'last-error     (get-ffi-obj 'pancake_iroh_last_error L (_fun _pointer _size -> _size))
   'netlayer-new   (get-ffi-obj 'pancake_iroh_netlayer_new L
                     (_fun _pointer _size _uint32 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
   'netlayer-close (get-ffi-obj 'pancake_iroh_netlayer_close L (_fun _pointer -> _void))
   'netlayer-release (get-ffi-obj 'pancake_iroh_netlayer_release L (_fun _pointer -> _void))
   'node-id        (get-ffi-obj 'pancake_iroh_netlayer_node_id L
                     (_fun _pointer _pointer _size (out : (_ptr o _size)) -> (r : _int32) -> (values r out)))
   'direct-addrs   (get-ffi-obj 'pancake_iroh_netlayer_direct_addrs L
                     (_fun _pointer _pointer _size (out : (_ptr o _size)) -> (r : _int32) -> (values r out)))
   'conn-release   (get-ffi-obj 'pancake_iroh_conn_release L (_fun _pointer -> _void))
   ;; The event-driven loop surface (ADR-0057): the netlayer's one I/O model.
   ;; Park a green thread on the readiness fd (via `unsafe-file-descriptor->semaphore`),
   ;; drain records when it signals, and drive non-blocking byte I/O, one place
   ;; serves many connections. `readiness-fd` returns the fd; `drain-ready` drains
   ;; into a caller-owned array (read with `ptr-ref`, so a plain pointer). Only
   ;; `try-connect` (the dial blocks) is #:blocking?; everything else never parks.
   'readiness-fd   (get-ffi-obj 'pancake_iroh_netlayer_readiness_fd L (_fun _pointer -> _int32))
   'drain-ready    (get-ffi-obj 'pancake_iroh_netlayer_drain_ready L
                     (_fun _pointer _pointer _size -> _intptr))
   'try-accept     (get-ffi-obj 'pancake_iroh_netlayer_try_accept L
                     (_fun _pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
   'try-connect    (get-ffi-obj 'pancake_iroh_netlayer_try_connect L
                     (_fun #:blocking? #t _pointer _pointer _size _pointer _size
                           (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
   'conn-try-read  (get-ffi-obj 'pancake_iroh_conn_try_read L (_fun _pointer _pointer _size -> _intptr))
   'conn-try-write (get-ffi-obj 'pancake_iroh_conn_try_write L (_fun _pointer _pointer _size -> _intptr))))

(define (iroh-fn key) (hash-ref (iroh-ffi) key))
