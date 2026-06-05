#lang racket/base

;; Stack 4 verification: STOCK Spritely Goblins (goblins/ocapn/captp,
;; unmodified) on BOTH ends, talking over the pancake iroh netlayer.
;; Modeled on goblins/ocapn/netlayer/fake-intarwebs.rkt's own test,
;; but the transport is real QUIC-over-iroh via pancake's FFI.

(require goblins
         goblins/vat
         goblins/ocapn/captp          ; STOCK spawn-mycapn (not pancake's captp.rkt)
         racket/async-channel
         (file "../pancake-iroh-goblins-netlayer.rkt"))

(define-vat-run a-run (make-vat))
(define-vat-run b-run (make-vat))

(define a-nl (a-run (spawn ^iroh-netlayer)))
(define b-nl (b-run (spawn ^iroh-netlayer)))

(define b-id (b-run ($ b-nl 'endpoint-id)))
(define b-addr (b-run ($ b-nl 'bound-addr)))
(printf "B endpoint-id=~a addr=~a\n" b-id b-addr)

(define a-mycapn (a-run (spawn-mycapn a-nl)))
(define b-mycapn (b-run (spawn-mycapn b-nl)))

(define (^greeter _bcom my-name)
  (lambda (your-name)
    (format "Hello ~a, my name is ~a!" your-name my-name)))

(define bob (b-run (spawn ^greeter "Bob")))
(define bob-sref (b-run ($ b-mycapn 'register bob 'iroh)))

;; Loopback: teach A's netlayer how to reach B's EndpointId (no discovery).
(a-run ($ a-nl 'register-peer-addr! b-id b-addr))

(define response-ch (make-async-channel))
(a-run
 (define bob-vow (<- a-mycapn 'enliven bob-sref))
 (on (<- bob-vow "Arthur")
     (lambda (val) (async-channel-put response-ch (list 'fulfilled val)))
     #:catch
     (lambda (err) (async-channel-put response-ch (list 'broken err)))))

(define result (sync/timeout 15 response-ch))
(printf "result: ~a\n" result)
(when (equal? result '(fulfilled "Hello Arthur, my name is Bob!"))
  (displayln "STACK4-LOOPBACK-OK"))
