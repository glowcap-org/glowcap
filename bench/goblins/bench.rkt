#lang racket/base
;; Orchestrator for the cross-implementation bench suite. For each selected suite
;; and each backend (goblins, pancake) it spawns the bench server as its own OS
;; process, waits for the NDJSON readiness line, runs the client measurements,
;; samples the server's RSS for the memory metric, then prints a pancake-vs-Goblins
;; comparison and writes a report under zig-out/bench-reports/.
;;
;; Flags: --suite=<echo|registry|mint|taskboard|all> (default all), --smoke (tiny
;; counts), --port=N (base port).
(require racket/string racket/list racket/port racket/file racket/format
         (file "/workspaces/pancake/bench/goblins/metrics.rkt")
         (file "/workspaces/pancake/bench/goblins/report.rkt"))

(define-values (suite-sel smoke? base-port)
  (let loop ([args (vector->list (current-command-line-arguments))]
             [suite "all"] [smoke #f] [port 19800])
    (cond
      [(null? args) (values suite smoke port)]
      [(regexp-match #px"^--suite=(.+)$" (car args))
       => (lambda (m) (loop (cdr args) (cadr m) smoke port))]
      [(equal? "--smoke" (car args)) (loop (cdr args) suite #t port)]
      [(regexp-match #px"^--port=(\\d+)$" (car args))
       => (lambda (m) (loop (cdr args) suite smoke (string->number (cadr m))))]
      [else (loop (cdr args) suite smoke port)])))

(define ALL-SUITES '("echo" "registry" "mint" "taskboard"))
(define SUITES (if (equal? suite-sel "all") ALL-SUITES (list suite-sel)))
;; Three series: standard Goblins, the pancake binding, and the pancake binding
;; with time-travel on for every actor (`pancake-tt`). Each is its own backend
;; module under bench/goblins/backend-<name>.rkt.
(define BACKENDS '("goblins" "pancake" "pancake-tt"))

(define LAT-N (if smoke? 20 2000))
(define TPUT-N (if smoke? 20 2000))
(define CONNS (if smoke? 4 50))

(define RACKET (find-executable-path "racket"))
(define SERVER "/workspaces/pancake/bench/goblins/server.rkt")
(define CLIENT "/workspaces/pancake/bench/goblins/client.rkt")
(define HOST "127.0.0.1")

;; (suite backend) -> alist of measured fields.
(define results (make-hash))
(define port-counter (box base-port))
(define (next-port!) (begin0 (unbox port-counter) (set-box! port-counter (+ (unbox port-counter) 7))))

;; Start a server process; wait for its NDJSON ready line; then drain its stdout in
;; a background thread so it never blocks. Returns (values proc pid).
(define (start-server backend suite port)
  ;; Capture the server's stderr (#f) and drain it to nowhere: a force-killed
  ;; Goblins vat prints captp teardown traces that are not failures and would
  ;; otherwise clutter the report.
  (define-values (proc out in err)
    (subprocess #f #f #f RACKET SERVER backend suite HOST (number->string port)))
  (let loop ()
    (define line (read-line out))
    (when (eof-object? line)
      (error 'start-server "~a/~a server exited before ready" backend suite))
    (unless (regexp-match? #px"\"event\":\"ready\"" line) (loop)))
  (thread (lambda () (let drain () (define l (read-line out)) (unless (eof-object? l) (drain)))))
  (thread (lambda () (let drain () (define l (read-line err)) (unless (eof-object? l) (drain)))))
  (values proc (subprocess-pid proc)))

;; Run a client measurement to completion; return its result NDJSON line.
(define (run-client backend suite port mode n [conns 1])
  (define-values (proc out in err)
    (subprocess #f #f (current-error-port) RACKET CLIENT backend suite HOST (number->string port)
                mode (number->string n) (number->string conns)))
  (define lines (port->lines out))
  (subprocess-wait proc)
  (or (findf (lambda (l) (regexp-match? #px"\"metric\"" l)) lines)
      (error 'run-client "no result from ~a/~a/~a" backend suite mode)))

;; Sample a pid's RSS `n` times `dt` seconds apart and keep the minimum — the
;; floor closest to the live set after a GC cycle, stripping transient allocation
;; spikes symmetrically rather than catching a process mid-collection.
(define (sample-min-rss pid n dt)
  (let loop ([best #f] [k 0])
    (if (>= k n)
        (or best 0)
        (let ([s (rss-kb-of-pid pid 'VmRSS)])
          (sleep dt)
          (loop (cond [(not s) best] [(not best) s] [else (min best s)]) (add1 k))))))

;; The connections + memory measurement. The client warms the accept path with
;; throwaway connections held through both samples, prints a "warmed" marker
;; (baseline sampled here, before the measured batch opens), then opens the
;; measured batch and prints its line (loaded sampled here, during the hold).
;; Returns (values connections-line base-rss loaded-rss).
(define (run-connections backend suite port pid conns)
  (define-values (proc out in err)
    (subprocess #f #f #f RACKET CLIENT backend suite HOST (number->string port)
                "connections" "0" (number->string conns)))
  ;; Drain stderr so a chatty teardown (50 Goblins vats closing) cannot fill the
  ;; pipe buffer and wedge the client at exit, which would hang the loop below.
  (thread (lambda () (let drain () (define l (read-line err)) (unless (eof-object? l) (drain)))))
  (define base (box 0))
  (define loaded (box 0))
  (define line (box #f))
  (let loop ()
    (define l (read-line out))
    (cond
      [(eof-object? l) (void)]
      [(regexp-match? #px"\"event\":\"warmed\"" l) (set-box! base (sample-min-rss pid 4 0.1)) (loop)]
      [(regexp-match? #px"\"metric\":\"connections\"" l)
       (set-box! line l) (set-box! loaded (sample-min-rss pid 12 0.15)) (loop)]
      [else (loop)]))
  (subprocess-wait proc)
  (unless (unbox line) (error 'run-connections "no connections result from ~a/~a" backend suite))
  (values (unbox line) (unbox base) (unbox loaded)))

;; Pull a "key":num or "key":"str" field out of an NDJSON line.
(define (jf line key)
  (define m (regexp-match (regexp (format "\"~a\":\"?([^,\"}]+)\"?" key)) line))
  (and m (cadr m)))

(define (bench-one suite backend)
  (define port (next-port!))
  (define-values (proc pid) (start-server backend suite port))
  (with-handlers ([(lambda (_) #t) (lambda (e) (subprocess-kill proc #t) (raise e))])
    (sleep 0.3)
    (define lat (run-client backend suite port "latency" LAT-N))
    (define tput (run-client backend suite port "throughput" TPUT-N))
    ;; connections + memory: the client warms the accept path, the orchestrator
    ;; samples the baseline at the "warmed" marker and the loaded RSS during the
    ;; held-open measured batch. The throwaway warmup connections are held through
    ;; both samples, so they cancel in the delta.
    (define-values (conn-line base-rss loaded-rss) (run-connections backend suite port pid CONNS))
    (subprocess-kill proc #t)
    (subprocess-wait proc)
    (hash-set! results (list suite backend)
               (list (cons 'p50 (jf lat "p50_ms"))
                     (cons 'p99 (jf lat "p99_ms"))
                     (cons 'p999 (jf lat "p999_ms"))
                     (cons 'rps (jf tput "rps"))
                     (cons 'conn_ms (jf conn-line "per_conn_ms"))
                     (cons 'base_rss base-rss)
                     (cons 'loaded_rss loaded-rss)
                     (cons 'per_conn_kb (real->decimal-string (/ (max 0 (- loaded-rss base-rss)) (max 1 CONNS)) 1))))))

(for ([suite (in-list SUITES)])
  (for ([backend (in-list BACKENDS)])
    (printf "running ~a / ~a ...\n" suite backend) (flush-output)
    (bench-one suite backend)))

;; ---- Report ----
(define (f r k) (if (and r (cdr (assq k r))) (cdr (assq k r)) "-"))
(define (row suite)
  (string-append
   (format "~a\n" suite)
   (string-join
    (for/list ([backend (in-list BACKENDS)])
      (define r (hash-ref results (list suite backend) #f))
      (format "  ~a  p50=~ams p99=~ams p999=~ams rps=~a setup=~ams/conn per_conn=~akB"
              backend (f r 'p50) (f r 'p99) (f r 'p999) (f r 'rps) (f r 'conn_ms) (f r 'per_conn_kb)))
    "\n")))

(define report
  (string-append
   "pancake vs Goblins — cross-implementation benchmark\n"
   (format "mode=~a suites=~a lat_n=~a tput_n=~a conns=~a\n\n"
           (if smoke? "smoke" "full") (string-join SUITES ",") LAT-N TPUT-N CONNS)
   (string-join (for/list ([s (in-list SUITES)]) (row s)) "\n\n")
   "\n"))

(display report)
(define out-dir "/workspaces/pancake/zig-out/bench-reports")
(make-directory* out-dir)
(define stamp (number->string (current-seconds)))
(define mode-str (if smoke? "smoke" "full"))

;; Text report (terminal-friendly).
(define txt-path (build-path out-dir (format "goblins-compare-~a.txt" stamp)))
(call-with-output-file txt-path (lambda (o) (display report o)) #:exists 'replace)

;; SVG bar charts (self-contained, no JS) — latency p50 and throughput.
(define (write-svg name title y-label key fmt)
  (define p (build-path out-dir (format "goblins-compare-~a-~a.svg" stamp name)))
  (define svg (render-svg-bars title y-label SUITES
                               (lambda (s b) (numof results s b key)) fmt))
  (call-with-output-file p (lambda (o) (display svg o)) #:exists 'replace)
  p)
(define lat-svg (write-svg "latency" "Latency p50 (ms, lower is better)" "ms" 'p50
                           (lambda (v) (~r v #:precision 2))))
(define tput-svg (write-svg "throughput" "Throughput (req/s, higher is better)" "req/s" 'rps
                            (lambda (v) (~r v #:precision 0))))

;; Markdown report (value table + Mermaid charts + the SVGs by relative name).
(define md-path (build-path out-dir (format "goblins-compare-~a.md" stamp)))
(define md (render-markdown SUITES results mode-str LAT-N TPUT-N CONNS
                            (list (cons 'latency (format "goblins-compare-~a-latency.svg" stamp))
                                  (cons 'throughput (format "goblins-compare-~a-throughput.svg" stamp)))))
(call-with-output-file md-path (lambda (o) (display md o)) #:exists 'replace)

(printf "\nreports written:\n  ~a\n  ~a\n  ~a\n  ~a\n" txt-path md-path lat-svg tput-svg)
