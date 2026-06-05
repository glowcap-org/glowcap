#lang racket/base

;; pancake-tcp-netlayer.rkt — Goblins-shaped netlayer that hands
;; pancake-ffi endpoint handles to the pancake-backed captp module.
;;
;; Same actor-shape as upstream's ^tcp-netlayer enough to slot
;; into (spawn-mycapn netlayer). Methods:
;;
;;   ($ nl 'install-pancake-connection-handler
;;      (lambda (endpoint remote-location) ...))
;;       Captp's hook; called for each accepted connection. The
;;       handler takes ownership of the endpoint; releases it via
;;       pancake-endpoint-tcp-close when its per-connection pump
;;       finishes.
;;
;;   ($ nl 'our-location)
;;       Symmetric with upstream's API; returns the bind address.
;;
;; Matrix #3 migration: pre-migration this used Racket's
;; tcp-listen + tcp-accept and handed raw (in-port, out-port)
;; pairs to the handler. Post-migration the listener +
;; accept-loop use pancake-ffi's endpoint surface; the binding
;; owns no socket FDs.

(provide ^pancake-tcp-netlayer
         (rename-out [^pancake-tcp-netlayer ^tcp-netlayer]))

(require goblins
         goblins/actor-lib/methods
         "pancake-ffi.rkt")

(define (^pancake-tcp-netlayer _bcom listen-host listen-port)
  (define our-loc (format "~a:~a" listen-host listen-port))
  ;; Plain Racket box (not a Goblins ^cell) because the accept
  ;; thread runs OUTSIDE any syscaller context — `$` would error
  ;; with "Sorry, this syscaller is closed for business!"
  (define handler-box (box #f))

  ;; Start the accept loop in a background thread so the actor's
  ;; constructor returns immediately. The accept loop calls the
  ;; handler (set later via install-pancake-connection-handler)
  ;; for each new connection.
  (define listener (pancake-endpoint-tcp-listen listen-host listen-port))
  ;; Accept timeout — must be > 0 so the accept call yields back
  ;; to Racket's scheduler between attempts. A blocking accept
  ;; would hold the OS thread inside Rust indefinitely; per-
  ;; connection pump threads (started by handler) would never
  ;; get scheduled.
  (define ACCEPT-TIMEOUT-MS 50)
  (define accept-thread
    (thread
      (lambda ()
        (let loop ()
          (with-handlers ([exn?
                           (lambda (e)
                             (eprintf "[pancake-tcp-netlayer] accept failed: ~a~n"
                                      (exn-message e)))])
            (define ep-or-would-block
              (pancake-endpoint-tcp-accept-timed listener ACCEPT-TIMEOUT-MS))
            (cond
              [(eq? ep-or-would-block 'would-block)
               ;; Yield to give per-connection pump threads CPU.
               (sleep 0.001)]
              [else
               (define handler (unbox handler-box))
               (cond
                 [handler (handler ep-or-would-block our-loc
                                   pancake-tcp-transport-ops our-loc)]
                 [else
                  (eprintf "[pancake-tcp-netlayer] connection accepted but no handler installed; closing~n")
                  (pancake-endpoint-tcp-close ep-or-would-block)])]))
          (loop)))))

  (methods
   [(install-pancake-connection-handler h)
    (set-box! handler-box h)]
   [(our-location) our-loc]))
