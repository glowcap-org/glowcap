#lang racket/base
;; Racket row of the live Goblins-listener matrix.

(require "../../bindings/racket/glowcap.rkt"
         "../../bindings/racket/glowcap-tcp.rkt")

(define ACTOR-SWISS "glowcapActorSwissnumABCDEFGH1234")
(define server (listen "127.0.0.1" 0))

(host-publish
 (server-host server)
 ACTOR-SWISS
 (lambda (_method . args)
   (define value (if (null? args) #"stranger" (car args)))
   (define who (if (bytes? value) (bytes->string/utf-8 value) (format "~a" value)))
   (format "Hello from a binding host: ~a" who)))

(printf "GOBLINS-LISTENER-READY ~a\n" (server-port server))
(flush-output)

(define session (accept server))
(dynamic-wind
 void
 (lambda () (session-serve session))
 (lambda ()
   (session-close! session)
   (server-close! server)))
