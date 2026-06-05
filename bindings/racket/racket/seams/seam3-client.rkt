#lang racket/base
;; Stack 3 CLIENT: stock Spritely Goblins (goblins/ocapn/captp) on the
;; pancake TCP+TLS netlayer — dials the pancake-OCapN host over TLS.
(require goblins goblins/vat
         goblins/ocapn/captp          ; STOCK
         goblins/ocapn/structs-urls   ; STOCK
         racket/async-channel
         (file "../pancake-tcp-tls-goblins-netlayer.rkt"))

(define ECHO-SWISS-NUM (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))
(define result-ch (make-async-channel))
(define a-vat (make-vat))
(a-vat 'run
  (lambda ()
    (define nl (spawn ^tcp-tls-netlayer "127.0.0.1" 22091))   ; client binds its own TLS port
    (define mycapn (spawn-mycapn nl))
    (define target (ocapn-node 'tcp-tls "127.0.0.1:22090" #f))
    (define sref (ocapn-sturdyref target ECHO-SWISS-NUM))
    (printf "[client] enlivening echo over tcp-tls -> 127.0.0.1:22090~n")
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
  (displayln "STACK3-TLS-OK"))
