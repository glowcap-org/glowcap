#lang racket/base
;; S2: the classic ocap mint/purse. The root mint's `make-purse` mints a fresh
;; purse capability with an initial balance; a purse supports `balance` and
;; `deposit`. One client unit creates a purse and deposits into it, exercising
;; capability creation, capability passing across the wire, and stateful turns.
(require "../dispatch.rkt")
(provide app-name server-build client-prepare result-ok?)

(define app-name 'mint)

(define (server-build mint-cap)
  (define (root _bcom)
    (define (make-purse initial)
      ;; The balance lives in the behavior, not a private box: `deposit` becomes
      ;; a new behavior carrying the updated balance. That keeps the state where
      ;; the vat can see it, so a time-travel snapshot captures and can rewind
      ;; it; a box would hide the balance from the snapshot. Identical observable
      ;; behavior on every backend (`bcom` is the same on Goblins and pancake).
      (define (purse bcom balance)
        (dispatch
         (list
          (cons 'balance (lambda () balance))
          (cons 'deposit (lambda (amt)
                           (define next (+ balance amt))
                           (bcom (purse bcom next) next))))))
      (mint-cap (lambda (bcom) (purse bcom initial))))
    (dispatch (list (cons 'make-purse make-purse))))
  root)

(define (client-prepare call root-cap)
  (lambda (_i)
    (define purse (call root-cap 'make-purse 100))
    (call purse 'deposit 5)))

(define (result-ok? v) (equal? v 105))
