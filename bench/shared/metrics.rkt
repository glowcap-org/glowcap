#lang racket/base
;; Backend-agnostic measurement helpers for the Racket bench harnesses: latency
;; percentiles, throughput math, and process RSS sampling from /proc. Pure
;; functions plus one filesystem read; no actor, peer, or substrate code lives
;; here. The substrate bench (bench/goblins) drives them; the per-language
;; consumer-cost bench (bench/langs) reimplements the same instrument natively in
;; its Zig orchestrator, so it needs no Racket on the driving path.

(require racket/list racket/port)

(provide percentile throughput-rps rss-kb-of-status rss-kb-of-pid mean)

;; Nearest-rank percentile (1-indexed ceil) over a list of reals. `p` in [0,1].
(define (percentile xs p)
  (define sorted (sort xs <))
  (define n (length sorted))
  (cond
    [(zero? n) 0]
    [else
     (define rank (max 1 (inexact->exact (ceiling (* p n)))))
     (list-ref sorted (min (sub1 n) (sub1 rank)))]))

;; Arithmetic mean of a list of reals (0 for the empty list).
(define (mean xs)
  (if (null? xs) 0 (/ (apply + xs) (exact->inexact (length xs)))))

;; ops over elapsed milliseconds -> requests/second.
(define (throughput-rps ops elapsed-ms)
  (if (<= elapsed-ms 0) 0.0 (/ ops (/ elapsed-ms 1000.0))))

;; Parse a /proc/<pid>/status blob for a `kB` field (VmRSS / VmHWM), in kB, or #f.
(define (rss-kb-of-status status field)
  (define rx (regexp (format "(?m:^~a:[ \t]*([0-9]+) kB)" field)))
  (define m (regexp-match rx status))
  (if m (string->number (cadr m)) #f))

;; Read VmRSS / VmHWM (kB) for a live pid, or #f if unreadable.
(define (rss-kb-of-pid pid field)
  (define path (format "/proc/~a/status" pid))
  (and (file-exists? path)
       (rss-kb-of-status (call-with-input-file path port->string) field)))
