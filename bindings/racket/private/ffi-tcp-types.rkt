#lang racket/base
;; Private C-layout vocabulary owned by libglowcap_net_transport_tcp.

(require ffi/unsafe
         "ffi-shared.rkt"
         "layouts-gen.rkt")

(provide (struct-out GlowcapTcpStreamOptions)
         (struct-out GlowcapTcpConfig)
         (struct-out GlowcapTcpOperationOptions)
         _GlowcapTcpStreamOptions
         _GlowcapTcpStreamOptions-pointer
         _GlowcapTcpConfig
         _GlowcapTcpConfig-pointer
         _GlowcapTcpOperationOptions
         _GlowcapTcpOperationOptions-pointer)

(define-cstruct _GlowcapTcpStreamOptions
  ([keepalive_idle_sec _uint32]
   [keepalive_interval_sec _uint32]
   [keepalive_count _uint32])
  #:malloc-mode 'atomic-interior)

(define-cstruct _GlowcapTcpConfig
  ([stream _GlowcapTcpStreamOptions])
  #:malloc-mode 'atomic-interior)

(define-cstruct _GlowcapTcpOperationOptions
  ([stream _GlowcapTcpStreamOptions])
  #:malloc-mode 'atomic-interior)

(pin-layout! '_GlowcapTcpStreamOptions _GlowcapTcpStreamOptions
             GLOWCAP-TCP-STREAM-OPTIONS-SIZE
             GLOWCAP-TCP-STREAM-OPTIONS-LAYOUT)
(pin-layout! '_GlowcapTcpConfig _GlowcapTcpConfig
             GLOWCAP-TCP-CONFIG-SIZE
             GLOWCAP-TCP-CONFIG-LAYOUT)
(pin-layout! '_GlowcapTcpOperationOptions _GlowcapTcpOperationOptions
             GLOWCAP-TCP-OPERATION-OPTIONS-SIZE
             GLOWCAP-TCP-OPERATION-OPTIONS-LAYOUT)
