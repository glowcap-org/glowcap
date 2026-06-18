#lang racket/base
;; The Racket-binding bench client for the per-language consumer-cost bench. It
;; drives the taskboard unit against the fixed Zig host through pancake's Racket
;; binding (the same `connect`/`conn-fetch`/`conn-send` the demos use) and prints
;; one NDJSON metric line in the shared schema (see bench/langs/contract.md).
;;
;;   racket racket_bench.rkt <mode> <host> <port> <n>
(file-stream-buffer-mode (current-output-port) 'line)

(require (file "/workspaces/pancake/bindings/racket/pancake.rkt")
         (file "/workspaces/pancake/bench/shared/metrics.rkt"))

(define args (current-command-line-arguments))
(define mode (vector-ref args 0))
(define host (vector-ref args 1))
(define port (string->number (vector-ref args 2)))
(define N (if (> (vector-length args) 3) (string->number (vector-ref args 3)) 0))

(define CLIENT "racket")
(define RUNTIME "racket-cs")

(define (now) (current-inexact-monotonic-milliseconds))

;; One bench unit: create a task, then assign/complete/status it, returning the
;; final status (the bytes #"done").
(define (run-unit c root)
  (define task (conn-send c root 'create #"benchmark"))
  (conn-send c task 'assign #"alice")
  (conn-send c task 'complete)
  (conn-send c task 'status))

;; The same four verbs as run-unit, but pipelined (ADR-0007, questioner half):
;; assign/complete/status are addressed at the answer `create` will resolve to —
;; the promise-ref `conn-send-promise` returns, passed as the target, without
;; settling it — so the unit costs one round trip instead of four. Only the final
;; status is settled (`conn-await`), which flushes the queued batch. The
;; throughput unit; run-unit stays sequential so the latency row keeps measuring
;; one round trip.
(define (run-unit-pipelined c root)
  (define create (conn-send-promise c root 'create #"benchmark"))
  (conn-send-promise c create 'assign #"alice")
  (conn-send-promise c create 'complete)
  (conn-await c (conn-send-promise c create 'status)))

(define (assert-ok v) (unless (equal? v #"done") (error 'racket-bench "bad status ~v" v)))

(define WARMUP (min N 500))

(define (warm+settle c root [unit run-unit])
  (for ([_ (in-range WARMUP)]) (assert-ok (unit c root)))
  (collect-garbage) (collect-garbage) (collect-garbage))

(define (run-latency)
  (define c (connect (tcp-locator host port)))
  (define root (conn-fetch c "root"))
  (warm+settle c root)
  (define lats
    (for/list ([_ (in-range N)])
      (define s (now))
      (assert-ok (run-unit c root))
      (- (now) s)))
  (connection-close! c)
  (printf "{\"v\":1,\"metric\":\"latency\",\"client\":\"~a\",\"suite\":\"taskboard\",\"n\":~a,\"p50_ms\":~a,\"p99_ms\":~a,\"p999_ms\":~a,\"mean_ms\":~a,\"runtime\":\"~a\",\"warmup_n\":~a}\n"
          CLIENT N
          (real->decimal-string (percentile lats 0.50) 4)
          (real->decimal-string (percentile lats 0.99) 4)
          (real->decimal-string (percentile lats 0.999) 4)
          (real->decimal-string (mean lats) 4)
          RUNTIME WARMUP))

(define (run-throughput)
  (define c (connect (tcp-locator host port)))
  (define root (conn-fetch c "root"))
  (warm+settle c root run-unit-pipelined)
  (define t0 (now))
  (for ([_ (in-range N)]) (assert-ok (run-unit-pipelined c root)))
  (define total (- (now) t0))
  (connection-close! c)
  (printf "{\"v\":1,\"metric\":\"throughput\",\"client\":\"~a\",\"suite\":\"taskboard\",\"n\":~a,\"total_ms\":~a,\"rps\":~a,\"runtime\":\"~a\",\"warmup_n\":~a}\n"
          CLIENT N
          (real->decimal-string total 2)
          (number->string (inexact->exact (round (throughput-rps N total))))
          RUNTIME WARMUP))

(define CONN-WARMUP (min N 5))

(define (run-connections)
  (define warm
    (for/list ([_ (in-range CONN-WARMUP)])
      (define c (connect (tcp-locator host port)))
      (conn-fetch c "root")
      c))
  (collect-garbage) (collect-garbage)
  (printf "{\"v\":1,\"event\":\"warmed\"}\n")
  (sleep 0.6)
  (define t0 (now))
  (define handles
    (for/list ([_ (in-range N)])
      (define c (connect (tcp-locator host port)))
      (conn-fetch c "root")
      c))
  (define total (- (now) t0))
  (printf "{\"v\":1,\"metric\":\"connections\",\"client\":\"~a\",\"suite\":\"taskboard\",\"conns\":~a,\"total_ms\":~a,\"per_conn_ms\":~a,\"runtime\":\"~a\"}\n"
          CLIENT N
          (real->decimal-string total 2)
          (real->decimal-string (/ total (max 1 N)) 4)
          RUNTIME)
  (sleep 2.5)
  (for ([c (in-list handles)]) (connection-close! c))
  (for ([c (in-list warm)]) (connection-close! c)))

(define (run-cold)
  (define c (connect (tcp-locator host port)))
  (define root (conn-fetch c "root"))
  (assert-ok (run-unit c root))
  (connection-close! c)
  (printf "{\"v\":1,\"event\":\"cold-done\",\"client\":\"~a\"}\n" CLIENT))

(case mode
  [("latency") (run-latency)]
  [("throughput") (run-throughput)]
  [("connections") (run-connections)]
  [("cold") (run-cold)]
  [else (error 'racket-bench "unknown mode ~a" mode)])

(flush-output)
(exit 0)
