#lang racket/base
;; Private C-layout vocabulary owned by libpancake_net_transport_tcp.

(require ffi/unsafe
         "ffi-shared.rkt"
         "layouts-gen.rkt")

(provide (struct-out PancakeTcpStreamOptions)
         (struct-out PancakeTcpConfig)
         (struct-out PancakeTcpOperationOptions)
         _PancakeTcpStreamOptions
         _PancakeTcpStreamOptions-pointer
         _PancakeTcpConfig
         _PancakeTcpConfig-pointer
         _PancakeTcpOperationOptions
         _PancakeTcpOperationOptions-pointer)

(define-cstruct _PancakeTcpStreamOptions
  ([keepalive_idle_sec _uint32]
   [keepalive_interval_sec _uint32]
   [keepalive_count _uint32])
  #:malloc-mode 'atomic-interior)

(define-cstruct _PancakeTcpConfig
  ([stream _PancakeTcpStreamOptions])
  #:malloc-mode 'atomic-interior)

(define-cstruct _PancakeTcpOperationOptions
  ([stream _PancakeTcpStreamOptions])
  #:malloc-mode 'atomic-interior)

(pin-layout! '_PancakeTcpStreamOptions _PancakeTcpStreamOptions
             PANCAKE-TCP-STREAM-OPTIONS-SIZE
             PANCAKE-TCP-STREAM-OPTIONS-LAYOUT)
(pin-layout! '_PancakeTcpConfig _PancakeTcpConfig
             PANCAKE-TCP-CONFIG-SIZE
             PANCAKE-TCP-CONFIG-LAYOUT)
(pin-layout! '_PancakeTcpOperationOptions _PancakeTcpOperationOptions
             PANCAKE-TCP-OPERATION-OPTIONS-SIZE
             PANCAKE-TCP-OPERATION-OPTIONS-LAYOUT)
