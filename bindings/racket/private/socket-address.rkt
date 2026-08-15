#lang racket/base
;; Private socket-address spelling shared by transport adapters.

(require racket/string)

(provide tcp-address-designator)

(define (tcp-address-designator host port)
  (if (and (string-contains? host ":")
           (not (and (string-prefix? host "[") (string-suffix? host "]"))))
      (format "[~a]:~a" host port)
      (format "~a:~a" host port)))
