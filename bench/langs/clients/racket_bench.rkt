#lang racket/base
;; The Racket-binding bench client for the per-language consumer-cost bench. It
;; drives the taskboard unit against the fixed Zig host through pancake's Racket
;; binding (the same `connect`/`session-fetch`/`session-send` the demos use) and prints
;; one NDJSON metric line in the shared schema (see bench/langs/contract.md).
;;
;;   racket racket_bench.rkt <mode> <host> <port> <n>
(file-stream-buffer-mode (current-output-port) 'line)

(require (file "/workspaces/pancake/bindings/racket/pancake.rkt")
         (file "/workspaces/pancake/bindings/racket/pancake-tcp.rkt")
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
  (define task (session-send c root 'create #"benchmark"))
  (session-send c task 'assign #"alice")
  (session-send c task 'complete)
  (session-send c task 'status))

;; The same four verbs as run-unit, but pipelined (ADR-0007, questioner half):
;; assign/complete/status are addressed at the answer `create` will resolve to —
;; the vow `session-send-promise` returns, passed as the target. assign/complete
;; are one-way deliveries; only status allocates an answer and is settled. The
;; unit costs one round trip without leaving discarded result vows behind.
(define (run-unit-pipelined c root)
  (define create (session-send-promise c root 'create #"benchmark"))
  (session-tell c create 'assign #"alice")
  (session-tell c create 'complete)
  (session-await c (session-send-promise c create 'status)))

(define (assert-ok v) (unless (equal? v #"done") (error 'racket-bench "bad status ~v" v)))

(define WARMUP (min N 500))

(define (warm+settle c root [unit run-unit])
  (for ([_ (in-range WARMUP)]) (assert-ok (unit c root)))
  (collect-garbage) (collect-garbage) (collect-garbage))

(define (run-latency)
  (define runtime (open-runtime #:providers (list (tcp-provider))))
  (define c (runtime-connect runtime (tcp-locator host port)))
  (define root (session-fetch c "root"))
  (warm+settle c root)
  (define lats
    (for/list ([_ (in-range N)])
      (define s (now))
      (assert-ok (run-unit c root))
      (- (now) s)))
  (session-close! c)
  (runtime-close! runtime)
  (printf "{\"v\":1,\"metric\":\"latency\",\"client\":\"~a\",\"suite\":\"taskboard\",\"n\":~a,\"p50_ms\":~a,\"p99_ms\":~a,\"p999_ms\":~a,\"mean_ms\":~a,\"runtime\":\"~a\",\"warmup_n\":~a}\n"
          CLIENT N
          (real->decimal-string (percentile lats 0.50) 4)
          (real->decimal-string (percentile lats 0.99) 4)
          (real->decimal-string (percentile lats 0.999) 4)
          (real->decimal-string (mean lats) 4)
          RUNTIME WARMUP))

(define (run-throughput)
  (define runtime (open-runtime #:providers (list (tcp-provider))))
  (define c (runtime-connect runtime (tcp-locator host port)))
  (define root (session-fetch c "root"))
  (warm+settle c root run-unit-pipelined)
  (define t0 (now))
  (for ([_ (in-range N)]) (assert-ok (run-unit-pipelined c root)))
  (define total (- (now) t0))
  (session-close! c)
  (runtime-close! runtime)
  (printf "{\"v\":1,\"metric\":\"throughput\",\"client\":\"~a\",\"suite\":\"taskboard\",\"n\":~a,\"total_ms\":~a,\"rps\":~a,\"runtime\":\"~a\",\"warmup_n\":~a}\n"
          CLIENT N
          (real->decimal-string total 2)
          (number->string (inexact->exact (round (throughput-rps N total))))
          RUNTIME WARMUP))

(define CONN-WARMUP (min N 5))

(define (open-held-connection)
  (define runtime (open-runtime #:providers (list (tcp-provider))))
  (with-handlers ([(lambda (_) #t)
                   (lambda (failure)
                     (runtime-close! runtime)
                     (raise failure))])
    (define session (runtime-connect runtime (tcp-locator host port)))
    (session-fetch session "root")
    (cons runtime session)))

(define (close-held-connection held)
  (session-close! (cdr held))
  (runtime-close! (car held)))

(define (run-connections)
  (define warm
    (for/list ([_ (in-range CONN-WARMUP)])
      (open-held-connection)))
  (collect-garbage) (collect-garbage)
  (printf "{\"v\":1,\"event\":\"warmed\"}\n")
  (sleep 0.6)
  (define t0 (now))
  (define handles
    (for/list ([_ (in-range N)])
      (open-held-connection)))
  (define total (- (now) t0))
  (printf "{\"v\":1,\"metric\":\"connections\",\"client\":\"~a\",\"suite\":\"taskboard\",\"conns\":~a,\"total_ms\":~a,\"per_conn_ms\":~a,\"runtime\":\"~a\"}\n"
          CLIENT N
          (real->decimal-string total 2)
          (real->decimal-string (/ total (max 1 N)) 4)
          RUNTIME)
  (sleep 2.5)
  (for ([held (in-list handles)]) (close-held-connection held))
  (for ([held (in-list warm)]) (close-held-connection held)))

(define (run-cold)
  (define runtime (open-runtime #:providers (list (tcp-provider))))
  (define c (runtime-connect runtime (tcp-locator host port)))
  (define root (session-fetch c "root"))
  (assert-ok (run-unit c root))
  (session-close! c)
  (runtime-close! runtime)
  (printf "{\"v\":1,\"event\":\"cold-done\",\"client\":\"~a\"}\n" CLIENT))

;; The local-turn counter: `hit` increments and returns the count, any other
;; verb errors. Spawned fresh per use, so the two paths of run-local never
;; share a count.
(define (^counter bcom)
  (define count (box 0))
  (lambda (method . args)
    (unless (eq? method 'hit) (error 'counter "no such method ~a" method))
    (set-box! count (add1 (unbox count)))
    (unbox count)))

;; min(N, 500) warmup hits, forced collections, then N measured sequential
;; send→settle units against `target`, asserting the final count equals
;; WARMUP + N. Returns the per-turn latencies in nanoseconds.
(define (measure-hits c target)
  (for ([_ (in-range WARMUP)]) (session-send c target 'hit))
  (collect-garbage) (collect-garbage) (collect-garbage)
  (define final (box 0))
  (define lats
    (for/list ([_ (in-range N)])
      (define s (now))
      (set-box! final (session-send c target 'hit))
      (* (- (now) s) 1e6)))
  (unless (equal? (unbox final) (+ WARMUP N))
    (error 'racket-bench "bad final count ~v (expected ~a)" (unbox final) (+ WARMUP N)))
  lats)

;; The `local` mode (see contract.md): (a) in_lang — a counter spawned on this
;; connection, dispatched in process by the binding's own local path; (b)
;; via_host — the same behavior published across a loopback pair inside this
;; process (listen on 127.0.0.1:0 + connect to itself), so every turn pays wire
;; codec, feed, trampoline, and marshal both ways. The orchestrator's host/port
;; arguments are unused; the pair is self-contained.
(define (run-local)
  (define srv (listen "127.0.0.1" 0))
  ;; The accept half on its own thread: accept the one dialer, publish the
  ;; counter (before serving, so the dialer's fetch cannot race it), and serve
  ;; until the dialer leaves.
  (thread
   (lambda ()
     ;; A failure before serving would strand the dialer in a blocked fetch,
     ;; so it fails the process loudly instead of dying quietly.
     (define conn
       (with-handlers ([(lambda (_) #t)
                        (lambda (e)
                          (eprintf "racket-bench local: accept/publish failed: ~a\n" e)
                          (exit 1))])
         (define conn (accept srv))
         (session-publish conn "counter" ^counter)
         conn))
     (with-handlers ([(lambda (_) #t) void]) (session-serve conn))))
  (define runtime (open-runtime #:providers (list (tcp-provider))))
  (define c (runtime-connect runtime
                             (tcp-locator "127.0.0.1" (server-port srv))))

  ;; (a) in_lang: the binding's in-process actor dispatch.
  (define local-counter (session-spawn c ^counter))
  (define in-lang (measure-hits c local-counter))

  ;; (b) via_host: the published counter across the loopback pair.
  (define far-counter (session-fetch c "counter"))
  (define via-host (measure-hits c far-counter))

  (session-close! c)
  (runtime-close! runtime)
  (server-close! srv)

  (define in-mean (mean in-lang))
  (define via-mean (mean via-host))
  (printf "{\"v\":1,\"metric\":\"local\",\"client\":\"~a\",\"suite\":\"local-turn\",\"n\":~a,\"in_lang_ns\":~a,\"in_lang_p99_ns\":~a,\"via_host_ns\":~a,\"via_host_p99_ns\":~a,\"ratio\":~a,\"runtime\":\"~a\",\"warmup_n\":~a}\n"
          CLIENT N
          (real->decimal-string in-mean 1)
          (real->decimal-string (percentile in-lang 0.99) 1)
          (real->decimal-string via-mean 1)
          (real->decimal-string (percentile via-host 0.99) 1)
          (real->decimal-string (if (> in-mean 0) (/ via-mean in-mean) 0) 2)
          RUNTIME WARMUP))

(case mode
  [("latency") (run-latency)]
  [("throughput") (run-throughput)]
  [("connections") (run-connections)]
  [("cold") (run-cold)]
  [("local") (run-local)]
  [else (error 'racket-bench "unknown mode ~a" mode)])

(flush-output)
(exit 0)
