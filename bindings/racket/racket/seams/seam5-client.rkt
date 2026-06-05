#lang racket/base
;; Stack 5 CLIENT (also the 4<->5 interop dialer): STOCK Spritely
;; Goblins on the pancake iroh netlayer, dialing the pancake-OCapN host.
(require goblins goblins/vat
         goblins/ocapn/captp          ; STOCK
         goblins/ocapn/structs-urls   ; STOCK
         racket/async-channel
         racket/file
         (file "../pancake-iroh-goblins-netlayer.rkt"))

(define ECHO-SWISS-NUM (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))

;; Wait for the host to publish its EndpointId + bound addr.
(let wait ([n 0])
  (unless (file-exists? "/tmp/stack5-host.addr")
    (when (< n 200) (sleep 0.1) (wait (+ n 1)))))
(define lines (file->lines "/tmp/stack5-host.addr"))
(define host-eid (car lines))
(define host-addr (cadr lines))
(printf "[client] host eid=~a addr=~a~n" host-eid host-addr)

(define result-ch (make-async-channel))
(define a-vat (make-vat))
(a-vat 'run
  (lambda ()
    (define nl (spawn ^iroh-netlayer))
    ;; No discovery on loopback: teach our netlayer how to reach the host's EndpointId.
    ($ nl 'register-peer-addr! host-eid host-addr)
    (define mycapn (spawn-mycapn nl))
    (define target (ocapn-node 'iroh host-eid #f))
    (define sref (ocapn-sturdyref target ECHO-SWISS-NUM))
    (printf "[client] enlivening echo over iroh~n")
    (on (<- mycapn 'enliven sref)
        (lambda (echo)
          (printf "[client] enlivened; invoking echo \"hello\" \"world\"~n")
          (on (<- echo "hello" "world")
              (lambda (r)
                (printf "[client] echo returned: ~v~n" r)
                (async-channel-put result-ch (list 'ok r)))
              #:catch (lambda (e) (async-channel-put result-ch (list 'invoke-err e)))))
        #:catch (lambda (e) (async-channel-put result-ch (list 'enliven-err e))))))

(define result (sync/timeout 25 result-ch))
(printf "[client] result: ~a~n" result)
(when (equal? result '(ok ("hello" "world")))
  (displayln "STACK5-IROH-OK"))
