#lang racket/base
;; S1: a registry that hands back capability references. `lookup` mints a fresh
;; cell capability (via `mint-cap`) holding the looked-up key and returns it; the
;; client then invokes `get` on that returned capability over the wire. This
;; exercises the heart of CapTP, passing a live capability reference across the
;; connection and invoking it, as two sequential round-trips.
;;
;; Promise pipelining (invoking the returned promise before it resolves) is
;; deliberately not exercised: the client resolves the capability first and then
;; invokes it, so one app source runs the identical two-round-trip shape on both
;; substrates and the comparison rewards neither side's pipelining.
(require "../dispatch.rkt")
(provide app-name server-build client-prepare result-ok?)

(define app-name 'registry)

;; mint-cap : (constructor) -> capability-ref the partner can invoke.
(define (server-build mint-cap)
  (define (root _bcom)
    (define (lookup key)
      (define (cell _b)
        (dispatch (list (cons 'get (lambda () key)))))
      (mint-cap cell))
    (dispatch (list (cons 'lookup lookup))))
  root)

(define (client-prepare call root-cap)
  (lambda (i)
    (define key (string->bytes/utf-8 (number->string i)))
    (define cell (call root-cap 'lookup key))
    (call cell 'get)))

(define (result-ok? v) (bytes? v))
