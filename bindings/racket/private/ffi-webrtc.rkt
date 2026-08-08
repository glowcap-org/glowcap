#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_net_transport_webrtc.
;;
;; The WebRTC companion library (`libpancake_net_transport_webrtc`, ADR-0089) is
;; optional -- absent unless built with cargo -- so it loads lazily on first
;; `webrtc-fn` use, caching the bound table and naming the build step when the
;; library is absent. A peer is an opaque handle with no config struct, so there
;; is no cstruct to declare or layout to pin. Nothing here is public. The keyed
;; table itself is generated from the archive's annotated symbol inventory
;; (`ffi-webrtc-gen.rkt`, `zig build gen-binding-racket-ffi`); this module opens
;; the library and hands it to the generated table builder.
(require ffi/unsafe
         "constants-gen.rkt"
         "ffi-webrtc-gen.rkt"
         "ffi-shared.rkt"
         "layouts-gen.rkt"
         "lib-resolve.rkt")
(provide webrtc-fn
         _PancakeWebrtcReadyEvent
         PancakeWebrtcReadyEvent-subject PancakeWebrtcReadyEvent-events
         WEBRTC-EV-OPEN WEBRTC-EV-CANDIDATE WEBRTC-EV-READABLE
         WEBRTC-EV-WRITABLE WEBRTC-EV-CLOSED)

(define-cstruct _PancakeWebrtcReadyEvent ([subject _uintptr] [events _uint32])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeWebrtcReadyEvent _PancakeWebrtcReadyEvent
             PANCAKE-WEBRTC-READY-EVENT-SIZE PANCAKE-WEBRTC-READY-EVENT-LAYOUT)

(define webrtc-ffi-cache (box #f))

;; Open the webrtc ABI library and bind its symbols on first use, caching the
;; table. Optional, a clear error names the build step when it is absent.
(define (webrtc-ffi)
  (or (unbox webrtc-ffi-cache)
      (let ([table (load-webrtc-ffi)])
        (set-box! webrtc-ffi-cache table)
        table)))

(define (load-webrtc-ffi)
  (define L
    (open-pancake-archive "pancake_net_transport_webrtc"
     #:fail (lambda ()
              (error 'webrtc
                     (string-append
                      "webrtc transport unavailable: could not load libpancake_net_transport_webrtc from "
                      "PANCAKE_LIB_DIR, the abi-versioned cache, zig-out/lib, or the system library path. "
                      "Build it with `zig build webrtc-abi` (needs cargo).")))))
  (webrtc-ffi-table L))

(define (webrtc-fn key) (hash-ref (webrtc-ffi) key))
