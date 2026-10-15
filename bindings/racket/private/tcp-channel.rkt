#lang racket/base
;; Racket-runtime TCP realization for a byte-fed Host. FFI provider
;; construction and this connector are separate pieces of the TCP package.

(require racket/tcp
         "async.rkt")

(provide open-tcp-byte-transport)

(define (open-tcp-byte-transport host port)
  (define-values (in out) (tcp-connect host port))
  (port-transport in out))
