#lang racket/base

;; pancake-tcp-tls-netlayer.rkt — Goblins-shaped netlayer handing
;; pancake-ffi TCP+TLS connection handles to the pancake-backed captp
;; module (stack 3: pancake OCapN + pancake TCP+TLS netlayer).
;;
;; Structurally identical to pancake-tcp-netlayer.rkt — it differs
;; only in which `transport-ops` bundle it hands the pump and which
;; listen/accept FFI entry points it drives (the rustls-over-TCP
;; surface instead of cleartext). The captp pump is transport-agnostic
;; (see captp.rkt's `transport-ops` plumbing), so the OCapN-seam logic
;; is unchanged. (A future DRY pass can fold the three near-identical
;; captp-side netlayers — tcp / tcp-tls / iroh — behind one
;; constructor parameterized by listener ops; kept separate for now to
;; land working stacks first.)

(provide ^pancake-tcp-tls-netlayer
         (rename-out [^pancake-tcp-tls-netlayer ^tcp-tls-netlayer]))

(require goblins
         goblins/actor-lib/methods
         "pancake-ffi.rkt")

(define (^pancake-tcp-tls-netlayer _bcom listen-host listen-port)
  (define our-loc (format "~a:~a" listen-host listen-port))
  (define handler-box (box #f))
  (define listener (pancake-endpoint-tcp-tls-listen listen-host listen-port))
  (define ACCEPT-TIMEOUT-MS 50)
  (define accept-thread
    (thread
      (lambda ()
        (let loop ()
          (with-handlers ([exn?
                           (lambda (e)
                             (eprintf "[pancake-tcp-tls-netlayer] accept failed: ~a~n"
                                      (exn-message e)))])
            (define ep-or-would-block
              (pancake-endpoint-tcp-tls-accept-timed listener ACCEPT-TIMEOUT-MS))
            (cond
              [(eq? ep-or-would-block 'would-block)
               (sleep 0.001)]
              [else
               (define handler (unbox handler-box))
               (cond
                 [handler (handler ep-or-would-block our-loc
                                   pancake-tcp-tls-transport-ops our-loc)]
                 [else
                  (eprintf "[pancake-tcp-tls-netlayer] connection accepted but no handler installed; closing~n")
                  (pancake-endpoint-tcp-tls-close ep-or-would-block)])]))
          (loop)))))

  (methods
   [(install-pancake-connection-handler h)
    (set-box! handler-box h)]
   [(our-location) our-loc]))
