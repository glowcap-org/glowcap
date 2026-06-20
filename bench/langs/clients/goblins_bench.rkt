#lang racket/base
;; The Goblins reference client for the per-language consumer-cost bench. This is
;; the row that is NOT a pancake binding: it is Spritely Goblins, the reference
;; CapTP implementation in Racket, dialing the pancake host as an ordinary OCapN
;; peer. It owns its own vat and TCP netlayer per connection (the same shape one
;; pancake connection has), enlivens the host's published root, and drives the
;; taskboard unit with eventual-send and vat quiescence. It prints the shared
;; NDJSON schema (see bench/langs/contract.md) tagged "goblins-ref" so the reports
;; label it apart from the language rows.
;;
;;   racket goblins_bench.rkt <mode> <host> <port> <n>
(file-stream-buffer-mode (current-output-port) 'line)

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         (file "/workspaces/pancake/conformance/goblins-peer/racket/tcp-netlayer.rkt")
         (file "/workspaces/pancake/bench/shared/metrics.rkt")
         racket/async-channel)

(define args (current-command-line-arguments))
(define mode (vector-ref args 0))
(define HOST (vector-ref args 1))
(define PORT (string->number (vector-ref args 2)))
(define N (if (> (vector-length args) 3) (string->number (vector-ref args 3)) 0))

(define CLIENT "goblins-ref")
(define RUNTIME "racket-cs/goblins")

;; The pancake host publishes its board under the bootstrap swiss-num "root"
;; (`conn.publish("root", ...)` registers the literal bytes), so the Goblins peer
;; enlivens a sturdyref carrying exactly those bytes.
(define ROOT-SWISS (string->bytes/latin-1 "root"))

(define (now) (current-inexact-monotonic-milliseconds))

;; One client connection: its own vat, an ephemeral-port TCP netlayer, and a
;; mycapn over it, a distinct CapTP session, the same shape one pancake
;; connection has. One settle channel reused across the (sequential) calls.
(struct gconn (run mycapn ch))

(define (connect-one)
  (define vat (make-vat))
  (define mycapn
    (vat 'run (lambda () (define nl (spawn ^tcp-netlayer HOST 0)) (spawn-mycapn nl))))
  (gconn vat mycapn (make-async-channel)))

;; Run a thunk in the connection's vat (it posts its outcome to the channel) and
;; block, yielding to the vat threads, for that outcome.
(define (settle h thunk what)
  ((gconn-run h) 'run thunk)
  (define r (async-channel-get (gconn-ch h)))
  (if (eq? (car r) 'ok) (cdr r) (error 'goblins-bench "~a broke: ~a" what (cdr r))))

(define (fetch-root h)
  (define ch (gconn-ch h))
  (settle h
          (lambda ()
            (define node (ocapn-node 'tcp (format "~a:~a" HOST PORT) #f))
            (define sref (ocapn-sturdyref node ROOT-SWISS))
            (on (<- (gconn-mycapn h) 'enliven sref)
                (lambda (cap) (async-channel-put ch (cons 'ok cap)))
                #:catch (lambda (e) (async-channel-put ch (cons 'err e)))))
          'enliven))

(define (call h ref method . args)
  (define ch (gconn-ch h))
  (settle h
          (lambda ()
            (on (apply <- ref method args)
                (lambda (v) (async-channel-put ch (cons 'ok v)))
                #:catch (lambda (e) (async-channel-put ch (cons 'err e)))))
          method))

;; One bench unit: create -> assign -> complete -> status, returning the status.
(define (run-unit h root)
  (define task (call h root 'create #"benchmark"))
  (call h task 'assign #"alice")
  (call h task 'complete)
  (call h task 'status))

;; The same four verbs as run-unit, but pipelined through Goblins' own promise
;; pipelining: assign/complete/status eventual-send at the promise `create`
;; returns, in one vat turn, so the four delivers leave together and only the
;; final status is settled, the reference counterpart to the bindings' pipelined
;; throughput unit, keeping the row fair (the same workload, each stack's native
;; pipelining). run-unit stays sequential for the latency row.
(define (run-unit-pipelined h root)
  (define ch (gconn-ch h))
  (settle h
          (lambda ()
            (define create (<- root 'create #"benchmark"))
            (<- create 'assign #"alice")
            (<- create 'complete)
            (on (<- create 'status)
                (lambda (v) (async-channel-put ch (cons 'ok v)))
                #:catch (lambda (e) (async-channel-put ch (cons 'err e)))))
          'status))

(define (assert-ok v) (unless (equal? v #"done") (error 'goblins-bench "bad status ~v" v)))

(define WARMUP (min N 500))

(define (warm+settle h root [unit run-unit])
  (for ([_ (in-range WARMUP)]) (assert-ok (unit h root)))
  (collect-garbage) (collect-garbage) (collect-garbage))

(define (run-latency)
  (define h (connect-one))
  (define root (fetch-root h))
  (warm+settle h root)
  (define lats
    (for/list ([_ (in-range N)])
      (define s (now))
      (assert-ok (run-unit h root))
      (- (now) s)))
  (printf "{\"v\":1,\"metric\":\"latency\",\"client\":\"~a\",\"suite\":\"taskboard\",\"n\":~a,\"p50_ms\":~a,\"p99_ms\":~a,\"p999_ms\":~a,\"mean_ms\":~a,\"runtime\":\"~a\",\"warmup_n\":~a}\n"
          CLIENT N
          (real->decimal-string (percentile lats 0.50) 4)
          (real->decimal-string (percentile lats 0.99) 4)
          (real->decimal-string (percentile lats 0.999) 4)
          (real->decimal-string (mean lats) 4)
          RUNTIME WARMUP))

(define (run-throughput)
  (define h (connect-one))
  (define root (fetch-root h))
  (warm+settle h root run-unit-pipelined)
  (define t0 (now))
  (for ([_ (in-range N)]) (assert-ok (run-unit-pipelined h root)))
  (define total (- (now) t0))
  (printf "{\"v\":1,\"metric\":\"throughput\",\"client\":\"~a\",\"suite\":\"taskboard\",\"n\":~a,\"total_ms\":~a,\"rps\":~a,\"runtime\":\"~a\",\"warmup_n\":~a}\n"
          CLIENT N
          (real->decimal-string total 2)
          (number->string (inexact->exact (round (throughput-rps N total))))
          RUNTIME WARMUP))

(define CONN-WARMUP (min N 5))

(define (run-connections)
  (define warm
    (for/list ([_ (in-range CONN-WARMUP)])
      (define h (connect-one)) (fetch-root h) h))
  (collect-garbage) (collect-garbage)
  (printf "{\"v\":1,\"event\":\"warmed\"}\n")
  (sleep 0.6)
  (define t0 (now))
  (define handles
    (for/list ([_ (in-range N)])
      (define h (connect-one)) (fetch-root h) h))
  (define total (- (now) t0))
  (printf "{\"v\":1,\"metric\":\"connections\",\"client\":\"~a\",\"suite\":\"taskboard\",\"conns\":~a,\"total_ms\":~a,\"per_conn_ms\":~a,\"runtime\":\"~a\"}\n"
          CLIENT N
          (real->decimal-string total 2)
          (real->decimal-string (/ total (max 1 N)) 4)
          RUNTIME)
  (sleep 2.5))

(define (run-cold)
  (define h (connect-one))
  (define root (fetch-root h))
  (assert-ok (run-unit h root))
  (printf "{\"v\":1,\"event\":\"cold-done\",\"client\":\"~a\"}\n" CLIENT))

(case mode
  [("latency") (run-latency)]
  [("throughput") (run-throughput)]
  [("connections") (run-connections)]
  [("cold") (run-cold)]
  [else (error 'goblins-bench "unknown mode ~a" mode)])

;; Goblins leaves background vat/netlayer threads alive; exit promptly so the
;; orchestrator's subprocess-wait returns.
(flush-output)
(exit 0)
