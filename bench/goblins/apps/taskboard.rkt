#lang racket/base
;; S3: a task board mirroring pancake's cross-language demos. The board's `create`
;; mints a task capability; the task supports `assign`, `complete`, and `status`.
;; One client unit creates a task and drives it through assign -> complete ->
;; status, exercising a returned capability invoked several times over the wire.
;;
;; Status is carried as bytes, not a Racket symbol: an OCapN symbol round-trips as
;; a native symbol on Goblins but as the binding's `sym` struct on pancake, so a
;; symbol result would not compare equal across substrates. Bytes are bytes on
;; both, keeping the result — and therefore the check — substrate-agnostic.
(require (file "/workspaces/pancake/bench/goblins/dispatch.rkt"))
(provide app-name server-build client-prepare result-ok?)

(define app-name 'taskboard)

(define (server-build mint-cap)
  (define (root _bcom)
    (define (create title)
      (define state (box 'open))
      (define who (box #f))
      (define (task _b)
        (dispatch
         (list
          (cons 'assign (lambda (p) (set-box! who p) #"assigned"))
          (cons 'complete (lambda () (set-box! state #"done") #"done"))
          (cons 'status (lambda () (unbox state))))))
      (mint-cap task))
    (dispatch (list (cons 'create create))))
  root)

(define (client-prepare call root-cap)
  (lambda (_i)
    (define task (call root-cap 'create #"benchmark"))
    (call task 'assign #"alice")
    (call task 'complete)
    (call task 'status)))

(define (result-ok? v) (equal? v #"done"))
