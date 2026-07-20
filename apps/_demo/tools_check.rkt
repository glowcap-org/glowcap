#lang racket/base
;; Shared tools demo check helper.

(provide make-check)

(define (make-check nick)
  (lambda (label ok)
    (printf "~a: ~a, ~a\n" nick (if ok "ok" "FAIL") label)
    (flush-output)
    (unless ok (exit 1))))
