#lang racket/base
;; The binding's one compare-and-swap on a box.
;;
;; On aarch64, Racket CS's `box-cas!` can return #f while the box still holds
;; `old` and no other thread wrote it. A one-shot transition built on it then
;; drops a settle, claim, or first failure with no error: a listener stays
;; pending and its waiter parks forever. `box-cas-strong!` retries that case, so
;; #f means another writer moved the box first. Every binding module uses it in
;; place of `box-cas!`, and the suite's source guard holds that.

(provide box-cas-strong!)

(define (box-cas-strong! b old new)
  (let retry ()
    (cond
      [(box-cas! b old new) #t]
      [(eq? (unbox b) old) (retry)]
      [else #f])))
