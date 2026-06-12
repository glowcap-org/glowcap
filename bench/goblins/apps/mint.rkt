#lang racket/base
;; S2: the classic ocap mint/purse. The root mint's `make-purse` mints a fresh
;; purse capability with an initial balance; a purse supports `balance` and
;; `deposit`. One client unit creates a purse and deposits into it, exercising
;; capability creation, capability passing across the wire, and stateful turns.
(require (file "/workspaces/pancake/bench/goblins/dispatch.rkt"))
(provide app-name server-build client-prepare result-ok?)

(define app-name 'mint)

(define (server-build mint-cap)
  (define (root _bcom)
    (define (make-purse initial)
      (define bal (box initial))
      (define (purse _b)
        (dispatch
         (list
          (cons 'balance (lambda () (unbox bal)))
          (cons 'deposit (lambda (amt)
                           (set-box! bal (+ (unbox bal) amt))
                           (unbox bal))))))
      (mint-cap purse))
    (dispatch (list (cons 'make-purse make-purse))))
  root)

(define (client-prepare call root-cap)
  (lambda (_i)
    (define purse (call root-cap 'make-purse 100))
    (call purse 'deposit 5)))

(define (result-ok? v) (equal? v 105))
