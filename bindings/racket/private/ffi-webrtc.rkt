#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libglowcap_net_transport_webrtc.
;;
;; The WebRTC companion library (`libglowcap_net_transport_webrtc`, ADR-0089) is
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
         _GlowcapWebrtcReadyEvent
         GlowcapWebrtcReadyEvent-subject GlowcapWebrtcReadyEvent-events
         _GlowcapWebrtcStringView
         GlowcapWebrtcStringView-ptr GlowcapWebrtcStringView-len
         _GlowcapWebrtcIceServer
         GlowcapWebrtcIceServer-urls GlowcapWebrtcIceServer-url-count
         GlowcapWebrtcIceServer-username GlowcapWebrtcIceServer-credential
         _GlowcapWebrtcConfig _GlowcapWebrtcConfig-pointer make-GlowcapWebrtcConfig
         WEBRTC-EV-OPEN WEBRTC-EV-CANDIDATE WEBRTC-EV-READABLE
         WEBRTC-EV-WRITABLE WEBRTC-EV-CLOSED)

(define-cstruct _GlowcapWebrtcReadyEvent ([subject _uintptr] [events _uint32])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_GlowcapWebrtcReadyEvent _GlowcapWebrtcReadyEvent
             GLOWCAP-WEBRTC-READY-EVENT-SIZE GLOWCAP-WEBRTC-READY-EVENT-LAYOUT)

(define-cstruct _GlowcapWebrtcStringView ([ptr _pointer] [len _size])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_GlowcapWebrtcStringView _GlowcapWebrtcStringView
             GLOWCAP-WEBRTC-STRING-VIEW-SIZE GLOWCAP-WEBRTC-STRING-VIEW-LAYOUT)

(define-cstruct _GlowcapWebrtcIceServer
  ([urls _pointer]
   [url-count _size]
   [username _GlowcapWebrtcStringView]
   [credential _GlowcapWebrtcStringView])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_GlowcapWebrtcIceServer _GlowcapWebrtcIceServer
             GLOWCAP-WEBRTC-ICE-SERVER-SIZE GLOWCAP-WEBRTC-ICE-SERVER-LAYOUT)

(define-cstruct _GlowcapWebrtcConfig
  ([ice-servers _pointer]
   [ice-server-count _size]
   [include-loopback-candidates _uint32]
   [worker-threads _uint32])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_GlowcapWebrtcConfig _GlowcapWebrtcConfig
             GLOWCAP-WEBRTC-CONFIG-SIZE GLOWCAP-WEBRTC-CONFIG-LAYOUT)

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
    (open-glowcap-archive "glowcap_net_transport_webrtc"
     #:fail (lambda ()
              (error 'webrtc
                     (string-append
                      "webrtc transport unavailable: could not load libglowcap_net_transport_webrtc from "
                      "GLOWCAP_LIB_DIR, the abi-versioned cache, zig-out/lib, or the system library path. "
                      "Build it with `zig build webrtc-abi` (needs cargo).")))))
  (define table (webrtc-ffi-table L _GlowcapWebrtcConfig-pointer))
  (require-archive-fingerprint! 'webrtc (hash-ref table 'archive-fingerprint) WEBRTC-ARCHIVE-FINGERPRINT)
  table)

(define (webrtc-fn key) (hash-ref (webrtc-ffi) key))
