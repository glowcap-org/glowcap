#lang racket/base
;; Correctness of every app's logic, exercised in-process against a trivial
;; synchronous local substrate (no sockets). This proves the shared app source is
;; correct independent of substrate; the live network paths are proven by the
;; orchestrator's runs against real Goblins and pancake servers.
(require rackunit
         (prefix-in echo: (file "/workspaces/pancake/bench/goblins/apps/echo.rkt"))
         (prefix-in reg: (file "/workspaces/pancake/bench/goblins/apps/registry.rkt"))
         (prefix-in mint: (file "/workspaces/pancake/bench/goblins/apps/mint.rkt"))
         (prefix-in tb: (file "/workspaces/pancake/bench/goblins/apps/taskboard.rkt")))

;; Local substrate: mint-cap instantiates the constructor and returns its behavior
;; proc (directly callable); call invokes a behavior proc synchronously.
(define (local-mint ctor) (ctor 'bcom))
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
