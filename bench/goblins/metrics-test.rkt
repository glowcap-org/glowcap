#lang racket/base
;; Unit tests for the backend-agnostic metrics helpers.
(require rackunit
         "metrics.rkt")

(check-equal? (percentile (build-list 100 add1) 0.50) 50)
(check-equal? (percentile (build-list 100 add1) 0.99) 99)
(check-equal? (percentile '(5) 0.50) 5)
(check-equal? (percentile '() 0.50) 0)

(check-= (throughput-rps 1000 500.0) 2000.0 0.001)
(check-= (throughput-rps 0 0.0) 0.0 0.001)

(check-= (mean '(2 4 6)) 4.0 0.001)

(define sample "Name:\tracket\nVmHWM:\t  204800 kB\nVmRSS:\t  102400 kB\n")
(check-equal? (rss-kb-of-status sample 'VmRSS) 102400)
(check-equal? (rss-kb-of-status sample 'VmHWM) 204800)
(check-false (rss-kb-of-status "Name:\tx\n" 'VmRSS))

(printf "metrics-test OK\n")
