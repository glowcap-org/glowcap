#lang racket/base
;; TCP package composition for the native driver loop. The generic loop knows
;; only provider registration and transport occupancy; this module owns loading
;; the TCP archive and installing its complete profile package.

(require "ffi-driver.rkt"
         "ffi-tcp.rkt"
         "errors.rkt"
         "loop.rkt")

(provide driver-loop-add-tcp!)

(define (driver-loop-add-tcp! lp)
  (unless (driver-loop-has-transport? lp "tcp")
    (define-values (rc tcp-handle) (pancake_tcp_netlayer_new))
    (check-with rc (lambda () (read-last-error pancake_tcp_last_error)))
    (define package (make-PancakeTransportProvider 0 0 #f 0 #f #f #f))
    (with-handlers ([(lambda (_) #t)
                     (lambda (e) (pancake_tcp_netlayer_release tcp-handle) (raise e))])
      (check-with (pancake_tcp_transport_provider tcp-handle package)
                  (lambda () (read-last-error pancake_tcp_last_error)))
      (driver-loop-add-provider! lp package)
      ;; Registration retained the package; release the constructor's lease.
      (pancake_tcp_netlayer_release tcp-handle))))
