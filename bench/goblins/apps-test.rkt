#lang racket/base
;; Correctness of every app's logic, exercised in-process against a trivial
;; synchronous local substrate (no sockets). This proves the shared app source is
;; correct independent of substrate; the live network paths are proven by the
;; orchestrator's runs against real Goblins and pancake servers.
(require rackunit
         (prefix-in echo: "apps/echo.rkt")
         (prefix-in reg: "apps/registry.rkt")
         (prefix-in mint: "apps/mint.rkt")
         (prefix-in tb: "apps/taskboard.rkt"))

;; Local substrate. Goblins hands a constructor a `bcom` procedure, and two of
;; the apps below use it for real: the mint's purse and the taskboard's task both
;; return `(bcom next-behavior return-value)`, which swaps the actor's behavior
;; and yields the value. So `local-mint` supplies the same thing rather than a
;; stand-in, and the reference it returns reads the actor's *current* behavior
;; through a cell — otherwise a swap would be invisible to the next call.
(define (local-mint ctor)
  (define behavior #f)
  (define (bcom next [ret (void)])
    (set! behavior next)
    ret)
  (set! behavior (ctor bcom))
  (lambda (method . args) (apply behavior method args)))
(define (local-call ref method . args) (apply ref method args))
(define (build app-server-build) (local-mint (app-server-build local-mint)))

;; echo
(let ([root (build echo:server-build)])
  (check-true (echo:result-ok? ((echo:client-prepare local-call root) 0))))

;; registry, returns a capability that is then invoked
(let ([root (build reg:server-build)])
  (define v ((reg:client-prepare local-call root) 7))
  (check-equal? v #"7")
  (check-true (reg:result-ok? v)))

;; mint, deposit lands on the returned purse capability
(let ([root (build mint:server-build)])
  (define v ((mint:client-prepare local-call root) 0))
  (check-equal? v 105)
  (check-true (mint:result-ok? v)))

;; taskboard, assign/complete/status on the returned task capability
(let ([root (build tb:server-build)])
  (define v ((tb:client-prepare local-call root) 0))
  (check-equal? v #"done")
  (check-true (tb:result-ok? v)))

(printf "apps-test OK\n")
