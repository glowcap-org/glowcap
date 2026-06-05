#lang racket/base
;; Stack 3 HOST: pancake OCapN (captp.rkt) + pancake TCP+TLS netlayer.
(require goblins goblins/vat
         (file "../captp.rkt")
         (file "../pancake-tcp-tls-netlayer.rkt"))

(define ECHO-SWISS-NUM (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))
(define (^echo _bcom) (lambda args (printf "[host] echo ~v~n" args) args))

(define a-vat (make-vat))
(a-vat 'run
  (lambda ()
    (define nl (spawn ^tcp-tls-netlayer "127.0.0.1" 22090))
    (define mycapn (spawn-mycapn nl))
    (define reg ($ mycapn 'get-registry))
    ($ reg 'register (spawn ^echo) ECHO-SWISS-NUM)
    (printf "[host] ready on tcp-tls 127.0.0.1:22090~n")))
(sync (make-semaphore))
