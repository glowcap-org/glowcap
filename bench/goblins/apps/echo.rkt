#lang racket/base
;; S0 calibration: an echo actor returning its argument. No capability passing, so
;; `server-build` ignores `mint-cap`. One client unit is a single round-trip.
;; Backend-blind: uses only the procs the harness passes (a synchronous `call` on
;; the client, `mint-cap`/`dispatch` on the server).
(require "../dispatch.rkt")
(provide app-name server-build client-prepare result-ok?)

(define app-name 'echo)

;; mint-cap -> root constructor (lambda (bcom) behavior).
(define (server-build _mint-cap)
  (lambda (_bcom)
    (dispatch (list (cons 'echo (lambda (x) x))))))

;; call : (ref method . args) -> value (synchronous send + settle).
(define (client-prepare call root-cap)
  (lambda (_i) (call root-cap 'echo #"ping")))

(define (result-ok? v) (equal? v #"ping"))
