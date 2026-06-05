#lang racket/base

;; pancake-iroh-netlayer.rkt — Goblins-shaped netlayer that hands
;; pancake-ffi iroh connection handles to the pancake-backed captp
;; module (stack 5: pancake OCapN + pancake iroh netlayer).
;;
;; Same actor shape as pancake-tcp-netlayer.rkt — it slots into
;; `(spawn-mycapn netlayer)` and feeds captp's transport-agnostic pump
;; via `install-pancake-connection-handler`, handing it the iroh
;; `transport-ops` bundle per accepted connection. The only structural
;; difference from the TCP netlayer is addressing: iroh binds UDP at
;; construction (no listen host/port) and peers are named by base32
;; `EndpointId`, surfaced via the `endpoint-id` / `bound-addr` methods
;; so a dialer can locate this listener (direct-addr hint for
;; no-discovery loopback).

(provide ^pancake-iroh-netlayer
         (rename-out [^pancake-iroh-netlayer ^iroh-netlayer]))

(require goblins
         goblins/actor-lib/methods
         "pancake-ffi.rkt")

(define (^pancake-iroh-netlayer _bcom)
  ;; UDP is bound here (ephemeral port); the EndpointId + bound addr
  ;; are stable for this netlayer's lifetime.
  (define ep (pancake-endpoint-iroh-new))
  (define our-id (pancake-endpoint-iroh-endpoint-id ep))
  (define our-addr (pancake-endpoint-iroh-bound-addr ep))
  ;; Designator advertised in the handshake's acceptable_location.
  (define our-loc (format "iroh:~a" our-id))

  ;; Plain Racket box (not a Goblins ^cell): the accept thread runs
  ;; OUTSIDE any syscaller context — same constraint as the TCP
  ;; netlayer.
  (define handler-box (box #f))

  (define listener (pancake-endpoint-iroh-listen ep))
  ;; Accept timeout > 0 so the call yields back to Racket's scheduler
  ;; between attempts (a blocking accept would hold the OS thread in
  ;; Rust and starve the per-connection pump green threads).
  (define ACCEPT-TIMEOUT-MS 50)
  (define accept-thread
    (thread
      (lambda ()
        (let loop ()
          (with-handlers ([exn?
                           (lambda (e)
                             (eprintf "[pancake-iroh-netlayer] accept failed: ~a~n"
                                      (exn-message e)))])
            (define conn-or-would-block
              (pancake-endpoint-iroh-accept-timed listener ACCEPT-TIMEOUT-MS))
            (cond
              [(eq? conn-or-would-block 'would-block)
               (sleep 0.001)]
              [else
               (define handler (unbox handler-box))
               (cond
                 [handler
                  (handler conn-or-would-block our-loc
                           pancake-iroh-transport-ops our-loc)]
                 [else
                  (eprintf "[pancake-iroh-netlayer] connection accepted but no handler installed; closing~n")
                  (pancake-endpoint-iroh-conn-close conn-or-would-block)])]))
          (loop)))))

  (methods
   [(install-pancake-connection-handler h)
    (set-box! handler-box h)]
   [(our-location) our-loc]
   ;; iroh-specific surface so a dialer can locate this listener.
   [(endpoint-id) our-id]
   [(bound-addr) our-addr]))
