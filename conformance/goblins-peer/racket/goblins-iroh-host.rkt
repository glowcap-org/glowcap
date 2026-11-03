#lang racket/base
;; goblins-iroh-host.rkt: a Goblins vat reachable over iroh's encrypted QUIC.
;;
;; The vat runs its own CapTP, unchanged. Only the netlayer differs: instead of
;; `tcp-netlayer.rkt`'s cleartext socket it binds an iroh endpoint through
;; `iroh-netlayer.rkt`, so the vat is named by an Ed25519 endpoint key and the
;; bytes on the wire are QUIC. It publishes the OCapN conformance suite's
;; canonical echo cap and then waits to be dialed.
;;
;; Usage:
;;   racket goblins-iroh-host.rkt
;;
;; Stdout (line-buffered NDJSON), once the endpoint is bound and the cap is
;; registered:
;;   {"v":1,"event":"vat-ready","vat":"goblins-iroh","node-id":"<64 hex>","direct-addresses":"127.0.0.1:41234"}
;;   {"v":1,"event":"cap-published","vat":"goblins-iroh","name":"echo","swiss":"IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"}
;;
;; The driver reads the endpoint id and the direct addresses out of the first
;; line to build the `iroh` locator it dials, and the swiss-num out of the second
;; to bootstrap-fetch the cap.

(require goblins
         goblins/vat
         goblins/ocapn/captp
         (only-in "host-support.rkt" emit-ndjson ECHO-SWISS-NUM ^echo report-session)
         "iroh-netlayer.rkt"
         (only-in "../../../bindings/racket/glowcap-iroh.rkt" IROH-REACH-DIRECT))

;; Line-buffer stdout so the driver sees the readiness lines as they are printed
;; rather than block-buffered until exit.
(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

;; The Direct posture: no relays and no lookup service, dialed by endpoint id
;; plus the direct-address hints the readiness line carries. That is the right
;; posture for a driver on loopback, and it keeps the bracket off the network.
(define a-vat (make-vat))

(a-vat
 'run
 (lambda ()
   (define netlayer
     (spawn ^iroh-netlayer IROH-REACH-DIRECT #:session-trace report-session))
   (define mycapn (spawn-mycapn netlayer))
   (define nonce-registry ($ mycapn 'get-registry))
   (define echo (spawn ^echo))
   ($ nonce-registry 'register echo ECHO-SWISS-NUM)
   (on (<- netlayer 'our-location)
       (lambda (location)
         (define fields (struct->vector location))
         (define hints (vector-ref fields 3))
         (emit-ndjson
          `(("event" . "vat-ready")
            ("vat" . "goblins-iroh")
            ("node-id" . ,(vector-ref fields 2))
            ("direct-addresses" . ,(if (hash? hints)
                                       (hash-ref hints "direct-addresses" "")
                                       ""))))
         (emit-ndjson
          `(("event" . "cap-published")
            ("vat" . "goblins-iroh")
            ("name" . "echo")
            ("swiss" . ,(bytes->string/latin-1 ECHO-SWISS-NUM))))))))

(sync (make-semaphore))
