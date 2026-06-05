#lang racket/base
;; Stack 5 HOST: pancake OCapN (captp.rkt) + pancake iroh netlayer.
(require goblins goblins/vat
         (file "../captp.rkt")
         (file "../pancake-iroh-netlayer.rkt"))

(define ECHO-SWISS-NUM (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))
(define (^echo _bcom) (lambda args (printf "[host] echo ~v~n" args) args))

(define a-vat (make-vat))
(a-vat 'run
  (lambda ()
    (define nl (spawn ^iroh-netlayer))
    (define eid ($ nl 'endpoint-id))
    (define addr ($ nl 'bound-addr))
    (define mycapn (spawn-mycapn nl))
    (define reg ($ mycapn 'get-registry))
    ($ reg 'register (spawn ^echo) ECHO-SWISS-NUM)
    (call-with-output-file "/tmp/stack5-host.addr" #:exists 'replace
      (lambda (out) (fprintf out "~a~n~a~n" eid addr)))
    (printf "[host] ready iroh eid=~a addr=~a~n" eid addr)))
(sync (make-semaphore))
