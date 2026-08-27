#lang racket/base
;; tcp-demo.rkt — two Goblins peers chatting over real TCP via CapTP.
;;
;; Same shape as captp-demo.rkt (two-peer greeter exchange) but uses
;; the local `tcp-netlayer` instead of `fake-intarwebs`. The bytes
;; really flow through the OS's TCP stack — both peers are in this one
;; process, but each binds its own port and dials the other over the
;; loopback interface.
;;
;; This is the Goblins-only real-socket control. It proves the reference
;; netlayer independently of pancake; `goblins-interop` and the live
;; handoff/gift/exporter rows cover pancake on the other end of that seam.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         racket/async-channel)

;; The cap each peer hosts: a greeter that echoes back a name.
(define (^greeter _bcom my-name)
  (lambda (your-name)
    (format "Hello ~a, this is ~a (over TCP CapTP)!" your-name my-name)))

;; ============================================================================
;; Peer A, binds 127.0.0.1:9001
;; ============================================================================

(define a-port 9001)
(define-vat-run a-machine-run (make-vat))
(define a-netlayer
  (a-machine-run (spawn ^tcp-netlayer "127.0.0.1" a-port)))
(define a-mycapn
  (a-machine-run (spawn-mycapn a-netlayer)))

(define-vat-run a-vat-run (make-vat))
(define alice (a-vat-run (spawn ^greeter "Alice (TCP peer A)")))
(define alice-sturdyref
  (a-machine-run ($ a-mycapn 'register alice 'tcp)))
(printf "[demo] Side-A bound to 127.0.0.1:~a; greeter sturdyref: ~v~n"
        a-port alice-sturdyref)

;; ============================================================================
;; Peer B, binds 127.0.0.1:9002, dials A
;; ============================================================================

(define b-port 9002)
(define-vat-run b-machine-run (make-vat))
(define b-netlayer
  (b-machine-run (spawn ^tcp-netlayer "127.0.0.1" b-port)))
(define b-mycapn
  (b-machine-run (spawn-mycapn b-netlayer)))

(define-vat-run b-vat-run (make-vat))

(define response-ch (make-async-channel))

(b-vat-run
 (printf "[demo] Side-B (127.0.0.1:~a) enlivening sturdyref...~n" b-port)
 (define alice-vow (<- b-mycapn 'enliven alice-sturdyref))
 (printf "[demo] Side-B sending greeting via CapTP-over-TCP...~n")
 (on (<- alice-vow "Bob (TCP peer B)")
     (lambda (val)
       (async-channel-put response-ch `(ok ,val)))
     #:catch
     (lambda (err)
       (async-channel-put response-ch `(err ,err)))))

;; Generous timeout, TCP loopback is fast but we're starting from cold.
(define reply (sync/timeout 5.0 response-ch))

(case (and (pair? reply) (car reply))
  [(ok)
   (printf "~n[demo] OK — TCP CapTP roundtrip~n")
   (printf "       Side-B heard back: ~a~n" (cadr reply))
   (printf "       The bytes flowed through real TCP sockets on 127.0.0.1.~n")
   (printf "       This is the Goblins-only control used beside pancake's~n")
   (printf "       live cross-implementation matrices.~n")
   (exit 0)]
  [(err)
   (printf "~n[demo] FAILED — broken promise: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "~n[demo] FAILED — timeout (no reply within 5s)~n")
   (exit 1)])
