#lang racket/base
;; The friendly verbs every driver-loop server shares. `tcp-listen.rkt` and
;; `relay-listen.rkt` both return `make-loop-server` values, so the verbs live
;; here once and each transport module re-provides them; a program requiring
;; two transports sees one binding instead of a conflict.

(require racket/lazy-require
         "locator.rkt")

(lazy-require
 ["loop.rkt"
  (loop-server?
   loop-server-locator
   loop-server-host
   loop-server-accept
   loop-server-close!)])

(provide server?
         server-host
         server-locator
         server-uri
         server-close!
         accept)

(define (server? v) (loop-server? v))
(define (server-host s) (loop-server-host s))
(define (server-locator s) (loop-server-locator s))
(define (server-uri s) (format-locator-uri (server-locator s)))
(define (server-close! s) (loop-server-close! s))
(define (accept s) (loop-server-accept s))
