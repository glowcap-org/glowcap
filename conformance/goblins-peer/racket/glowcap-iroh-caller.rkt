#lang racket/base
;; glowcap-iroh-caller.rkt — a Goblins client that calls a glowcap actor over
;; iroh's encrypted QUIC.
;;
;; It is `glowcap-actor-call.rkt`'s sibling, and the only difference is the
;; netlayer: this one binds an iroh endpoint and dials the glowcap peer by its
;; endpoint id rather than by a socket address. The CapTP above it is the same
;; Goblins CapTP, enlivening the actor published behind a swiss-num and then
;; sending it one positional argument.
;;
;; The session it opens is also where the netlayer's provenance verdict can be
;; read. This end dialed an endpoint id, and QUIC completes a handshake only with
;; the holder of that key, so when the glowcap peer's hello claims the same id
;; the netlayer reports `authenticated-transport`: the transport itself proved
;; the partner's durable name. Over `tcp` the same session would report
;; `unauthenticated`, because a socket address proves nothing.
;;
;; Usage:
;;   racket glowcap-iroh-caller.rkt <node-id> <direct-addresses> <swiss-ascii> <message>
;;
;; Prints one `SESSION …` line per session the netlayer opens, then
;; `DIAL OK: <reply>` and exits 0 on success; `DIAL ERR: <err>` or `DIAL TIMEOUT`
;; and exits 1 otherwise.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         (submod goblins/ocapn/structs-urls marshall)
         "iroh-netlayer.rkt"
         (only-in "../../../bindings/racket/glowcap-iroh.rkt" IROH-REACH-DIRECT)
         racket/async-channel)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))
(define node-id          (vector-ref argv 0))
(define direct-addresses (vector-ref argv 1))
(define swiss-ascii      (vector-ref argv 2))
(define message          (vector-ref argv 3))

;; The wire constructor rather than the contracted one: an `iroh` locator's hints
;; are the draft's mapping shape, which the contracted `ocapn-node` refuses.
(define make-wire-ocapn-node (cdr unmarshall::ocapn-node))

(define (report-session event _handle info)
  (when (eq? event 'open)
    (printf "SESSION transport=~a provenance=~a partner=~a session-id=~a~n"
            (hash-ref info 'transport)
            (hash-ref info 'durable-provenance)
            (hash-ref info 'partner-designator)
            (hash-ref info 'session-id))))

;; Settled outside the vat so the outer thread can `sync/timeout` on it without
;; blocking the vat that has to deliver the resolution.
(define response-ch (make-async-channel))
(define dialer-vat (make-vat))

(dialer-vat
 'run
 (lambda ()
   (define netlayer
     (spawn ^iroh-netlayer IROH-REACH-DIRECT #:session-trace report-session))
   (define mycapn (spawn-mycapn netlayer))

   (define target
     (ocapn-sturdyref
      (make-wire-ocapn-node 'iroh node-id (hash "direct-addresses" direct-addresses))
      (string->bytes/latin-1 swiss-ascii)))

   (on (<- mycapn 'enliven target)
       (lambda (actor)
         ;; The cap is live now, so this is a plain (non-pipelined) deliver.
         (on (<- actor message)
             (lambda (val) (async-channel-put response-ch `(ok ,val)))
             #:catch
             (lambda (err) (async-channel-put response-ch `(err ,err)))))
       #:catch
       (lambda (err) (async-channel-put response-ch `(err ,err))))))

(define reply (sync/timeout 30.0 response-ch))
(case (and (pair? reply) (car reply))
  [(ok)
   (printf "DIAL OK: ~v~n" (cadr reply))
   (exit 0)]
  [(err)
   (printf "DIAL ERR: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "DIAL TIMEOUT~n")
   (exit 1)])
