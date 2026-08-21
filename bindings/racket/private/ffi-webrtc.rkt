#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_net_transport_webrtc.
;;
;; The WebRTC companion library (`libpancake_net_transport_webrtc`, ADR-0089) is
;; optional -- absent unless built with cargo -- so it loads lazily on first
;; `webrtc-fn` use, caching the bound table and naming the build step when the
;; library is absent. Peers are opaque; the endpoint config and readiness record
;; are concrete ABI structs pinned below. Nothing here is public. The keyed
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
         _PancakeWebrtcStringView
         PancakeWebrtcStringView-ptr PancakeWebrtcStringView-len
         _PancakeWebrtcIceServer
         PancakeWebrtcIceServer-urls PancakeWebrtcIceServer-url-count
         PancakeWebrtcIceServer-username PancakeWebrtcIceServer-credential
         _PancakeWebrtcConfig _PancakeWebrtcConfig-pointer make-PancakeWebrtcConfig
         WEBRTC-EV-OPEN WEBRTC-EV-CANDIDATE WEBRTC-EV-READABLE
         WEBRTC-EV-WRITABLE WEBRTC-EV-CLOSED)

(define-cstruct _PancakeWebrtcReadyEvent ([subject _uintptr] [events _uint32])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeWebrtcReadyEvent _PancakeWebrtcReadyEvent
             PANCAKE-WEBRTC-READY-EVENT-SIZE PANCAKE-WEBRTC-READY-EVENT-LAYOUT)

(define-cstruct _PancakeWebrtcStringView ([ptr _pointer] [len _size])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeWebrtcStringView _PancakeWebrtcStringView
             PANCAKE-WEBRTC-STRING-VIEW-SIZE PANCAKE-WEBRTC-STRING-VIEW-LAYOUT)

(define-cstruct _PancakeWebrtcIceServer
  ([urls _pointer]
   [url-count _size]
   [username _PancakeWebrtcStringView]
   [credential _PancakeWebrtcStringView])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeWebrtcIceServer _PancakeWebrtcIceServer
             PANCAKE-WEBRTC-ICE-SERVER-SIZE PANCAKE-WEBRTC-ICE-SERVER-LAYOUT)

(define-cstruct _PancakeWebrtcConfig
  ([ice-servers _pointer]
   [ice-server-count _size]
   [include-loopback-candidates _uint32]
   [worker-threads _uint32])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeWebrtcConfig _PancakeWebrtcConfig
             PANCAKE-WEBRTC-CONFIG-SIZE PANCAKE-WEBRTC-CONFIG-LAYOUT)

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
  (define table (webrtc-ffi-table L _PancakeWebrtcConfig-pointer))
  (require-archive-fingerprint! 'webrtc (hash-ref table 'archive-fingerprint) WEBRTC-ARCHIVE-FINGERPRINT)
  table)

(define (webrtc-fn key) (hash-ref (webrtc-ffi) key))
