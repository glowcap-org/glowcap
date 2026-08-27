#lang racket/base
;; Bench client: racket client.rkt <backend> <suite> <host> <port> <mode> <n> [conns].
;; Connects to a running bench server and runs ONE measurement, printing an NDJSON
;; result line:
;;   latency     — N units, each a synchronous round-trip; p50/p99/p999/mean (ms)
;;   throughput  — N units back-to-back; requests/second (sequential, fair to both)
;;   connections — open `conns` sessions, fetch the root on each; total + per-conn
;;                 setup ms, then hold them open ~1s for the orchestrator's RSS
;;                 sample
;; A "unit" is the app's client thunk, which may make several round-trips (e.g. a
;; capability lookup followed by an invocation); the harness times the whole unit.
(file-stream-buffer-mode (current-output-port) 'line)

(require racket/runtime-path)
(require "metrics.rkt")

(define-runtime-path here ".")
(define args (current-command-line-arguments))
(define backend-name (vector-ref args 0))
(define suite (vector-ref args 1))
(define host (vector-ref args 2))
(define port (string->number (vector-ref args 3)))
(define mode (vector-ref args 4))
(define N (string->number (vector-ref args 5)))
(define CONNS (if (> (vector-length args) 6) (string->number (vector-ref args 6)) 1))

(define backend-path
  (build-path here (format "backend-~a.rkt" backend-name)))
(define app-path
  (build-path here "apps" (format "~a.rkt" suite)))

(define client-connect (dynamic-require backend-path 'client-connect))
(define client-fetch   (dynamic-require backend-path 'client-fetch))
(define client-call    (dynamic-require backend-path 'client-call))
(define client-close   (dynamic-require backend-path 'client-close))

(define client-prepare (dynamic-require app-path 'client-prepare))
(define result-ok?     (dynamic-require app-path 'result-ok?))

(define (now) (current-inexact-monotonic-milliseconds))

;; The `call` proc handed to the app: synchronous send + settle on this handle.
(define (make-call handle)
  (lambda (ref method . args) (apply client-call handle ref method args)))

;; Both substrates are Racket/Chez: the first few hundred units pay JIT and
;; initial-heap-growth costs, and Goblins has more code to warm. A generous,
;; identical warmup brings both to steady state so the measured window reflects
;; the substrate, not its startup transient. Capped so smoke runs stay fast.
(define WARMUP (min N (if (< N 100) (quotient N 2) 500)))

;; Run the warmup units, then force a full collection so warmup-phase garbage is
;; reclaimed *before* the measured window opens. Per-operation GC during the
;; window is still measured (it is a real cost of the substrate's allocation
;; rate); only the one-time warmup garbage is excluded. Symmetric across backends.
(define (warm+settle unit)
  (for ([i (in-range WARMUP)]) (unit i))
  (collect-garbage) (collect-garbage) (collect-garbage))

(define (run-latency)
  (define handle (client-connect host port))
  (define root (client-fetch handle "root"))
  (define unit (client-prepare (make-call handle) root))
  (warm+settle unit)
  (define lats
    (for/list ([i (in-range N)])
      (define s (now))
      (define v (unit i))
      (unless (result-ok? v) (error 'latency "bad result ~v" v))
      (- (now) s)))
  (client-close handle)
  (printf "{\"v\":1,\"metric\":\"latency\",\"backend\":\"~a\",\"suite\":\"~a\",\"n\":~a,\"p50_ms\":~a,\"p99_ms\":~a,\"p999_ms\":~a,\"mean_ms\":~a}\n"
          backend-name suite N
          (real->decimal-string (percentile lats 0.50) 4)
          (real->decimal-string (percentile lats 0.99) 4)
          (real->decimal-string (percentile lats 0.999) 4)
          (real->decimal-string (mean lats) 4)))

(define (run-throughput)
  (define handle (client-connect host port))
  (define root (client-fetch handle "root"))
  (define unit (client-prepare (make-call handle) root))
  (warm+settle unit)
  (define t0 (now))
  (for ([i (in-range N)])
    (define v (unit i))
    (unless (result-ok? v) (error 'throughput "bad result ~v" v)))
  (define total (- (now) t0))
  (client-close handle)
  (printf "{\"v\":1,\"metric\":\"throughput\",\"backend\":\"~a\",\"suite\":\"~a\",\"n\":~a,\"total_ms\":~a,\"rps\":~a}\n"
          backend-name suite N
          (real->decimal-string total 2)
          (number->string (inexact->exact (round (throughput-rps N total))))))

;; Warm the accept/connect/fetch path with a few throwaway connections that are
;; held open through *both* the orchestrator's baseline and loaded RSS samples, so
;; their cost cancels in the delta while the server's accept path is JIT-compiled
;; before the measured batch. This is symmetric — both substrates open the same
;; throwaways — and avoids relying on connection close, which the Goblins slim
;; netlayer cannot do cleanly.
(define CONN-WARMUP (min CONNS 5))

(define (run-connections)
  (define warm
    (for/list ([_ (in-range CONN-WARMUP)])
      (define h (client-connect host port))
      (client-fetch h "root")
      h))
  (collect-garbage) (collect-garbage)
  (printf "{\"v\":1,\"event\":\"warmed\"}\n") ; orchestrator samples the baseline here
  (sleep 0.6)                                 ; let the baseline sample finish before measuring
  (define t0 (now))
  (define handles
    (for/list ([_ (in-range CONNS)])
      (define handle (client-connect host port))
      (client-fetch handle "root")
      handle))
  (define total (- (now) t0))
  (printf "{\"v\":1,\"metric\":\"connections\",\"backend\":\"~a\",\"suite\":\"~a\",\"conns\":~a,\"total_ms\":~a,\"per_conn_ms\":~a}\n"
          backend-name suite CONNS
          (real->decimal-string total 2)
          (real->decimal-string (/ total (max 1 CONNS)) 4))
  (sleep 2.5) ; hold connections open while the orchestrator takes repeated RSS samples
  (for ([h (in-list handles)]) (client-close h))
  (for ([h (in-list warm)]) (client-close h)))

(case mode
  [("latency") (run-latency)]
  [("throughput") (run-throughput)]
  [("connections") (run-connections)]
  [else (error 'client "unknown mode ~a" mode)])

;; Exit promptly: Goblins leaves background vat/netlayer threads alive, which
;; would otherwise keep the process from terminating and block the orchestrator's
;; subprocess-wait.
(flush-output)
(exit 0)
