#lang racket/base
;; S3: a task board mirroring glowcap's cross-language demos. The board's `create`
;; mints a task capability; the task supports `assign`, `complete`, and `status`.
;; One client unit creates a task and drives it through assign -> complete ->
;; status, exercising a returned capability invoked several times over the wire.
;;
;; Status is carried as bytes, not a Racket symbol: an OCapN symbol round-trips as
;; a native symbol on Goblins but as the binding's `sym` struct on glowcap, so a
;; symbol result would not compare equal across substrates. Bytes are bytes on
;; both, keeping the result — and therefore the check — substrate-agnostic.
(require "../dispatch.rkt")
(provide app-name server-build client-prepare result-ok?)

(define app-name 'taskboard)

(define (server-build mint-cap)
  (define (root _bcom)
    (define (create title)
      ;; Status and assignee live in the behavior, not private boxes: `assign`
      ;; and `complete` become a new behavior carrying the updated state. That
      ;; keeps the state where the vat can see it, so a time-travel snapshot
      ;; captures and can rewind it, boxes would hide it. Identical observable
      ;; behavior on every backend (`bcom` is the same on Goblins and glowcap).
      (define (task bcom state who)
        (dispatch
         (list
          (cons 'assign (lambda (p) (bcom (task bcom state p) #"assigned")))
          (cons 'complete (lambda () (bcom (task bcom #"done" who) #"done")))
          (cons 'status (lambda () state)))))
      (mint-cap (lambda (bcom) (task bcom 'open #f))))
    (dispatch (list (cons 'create create))))
  root)

(define (client-prepare call root-cap)
  (lambda (_i)
    (define task (call root-cap 'create #"benchmark"))
    (call task 'assign #"alice")
    (call task 'complete)
    (call task 'status)))

(define (result-ok? v) (equal? v #"done"))
