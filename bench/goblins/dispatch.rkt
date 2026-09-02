#lang racket/base
;; A plain method-dispatch behavior builder used by every bench app. It does the
;; same job as the `methods` macro both substrates ship, but as a backend-blind
;; function, so one app source runs on Goblins and glowcap without importing
;; either's macro. The leading method symbol selects the handler; `($ obj 'm a)`
;; and `(<- obj 'm a)` both land here because both substrates pass the leading
;; symbol through to the behavior.
(provide dispatch)

(define (dispatch table)
  (lambda (method . args)
    (define h (assq method table))
    (if h (apply (cdr h) args) (error 'dispatch "no method: ~a" method))))
