#lang racket/base
;; Orchestrator for the cross-implementation bench suite. For each selected suite
;; and each backend (goblins, glowcap) it spawns the bench server as its own OS
;; process, waits for the NDJSON readiness line, runs the client measurements,
;; samples the server's RSS for the memory metric, then prints a glowcap-vs-Goblins
;; comparison and writes a report under zig-out/bench-reports/.
;;
;; Flags: --suite=<echo|registry|mint|taskboard|all> (default all), --smoke (tiny
;; counts), --port=N (base port).
(require racket/runtime-path)
(require racket/string racket/list racket/port racket/file racket/format
         "metrics.rkt"
         "report.rkt")

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
;; Three series: standard Goblins, the glowcap binding, and the glowcap binding
;; with time-travel on for every actor (`glowcap-tt`). Each is its own backend
;; module under bench/goblins/backend-<name>.rkt.
(define BACKENDS '("goblins" "glowcap" "glowcap-tt"))

(define LAT-N (if smoke? 20 2000))
(define TPUT-N (if smoke? 20 2000))
(define CONNS (if smoke? 4 50))

;; Children run with `-y`, as the build runs this file, so each checks its
;; compiled dependencies. Without it a module whose source is unchanged keeps
;; its `.zo`, along with any constant it inlined from a module that changed,
;; such as the binding's archive fingerprint.
(define RACKET (find-executable-path "racket"))
(define-runtime-path SERVER "server.rkt")
(define-runtime-path CLIENT "client.rkt")
(define-runtime-path repo-root "../..")
(define HOST "127.0.0.1")

;; (suite backend) -> alist of measured fields.
(define results (make-hash))
(define port-counter (box base-port))
(define (next-port!) (begin0 (unbox port-counter) (set-box! port-counter (+ (unbox port-counter) 7))))

;; Every child owns its pipes and reader threads from spawn through exit. One
;; deadline covers reading AND process termination: EOF alone is not success.
;; Keep the last 8 KiB of stderr so failures retain their cause without letting
;; noisy teardown consume unbounded memory or clutter successful reports.
(define child-timeout-seconds (make-parameter (if smoke? 30 120)))
(define stop-grace-seconds (make-parameter 5))
(struct child (proc out custody diagnostic stderr-reader label))

(define (spawn-child label script . args)
  (define custody (make-custodian))
  (with-handlers ([exn? (lambda (e) (custodian-shutdown-all custody) (raise e))])
    (parameterize ([current-custodian custody]
                   [current-subprocess-custodian-mode 'kill])
      (define-values (proc out in err)
        (apply subprocess #f #f #f RACKET "-y" script args))
      (close-output-port in)
      (define diagnostic (box #""))
      (define stderr-reader
        (thread
         (lambda ()
           (define buffer (make-bytes 1024))
           (let loop ()
             (define count (read-bytes-avail! buffer err))
             (unless (eof-object? count)
               (define joined (bytes-append (unbox diagnostic) (subbytes buffer 0 count)))
               (set-box! diagnostic (subbytes joined (max 0 (- (bytes-length joined) 8192))))
               (loop))))))
      (child proc out custody diagnostic stderr-reader label))))

(define (child-error process message)
  (error 'benchmark "~a: ~a~a" (child-label process) message
         (if (zero? (bytes-length (unbox (child-diagnostic process)))) ""
             (format "\nstderr (tail):\n~a"
                     (bytes->string/utf-8 (unbox (child-diagnostic process)) #\?)))))

(define (deadline)
  (+ (current-inexact-monotonic-milliseconds) (* 1000 (child-timeout-seconds))))
(define (await! process event until phase)
  (unless (sync/timeout (max 0 (/ (- until (current-inexact-monotonic-milliseconds)) 1000)) event)
    (child-error process (format "timed out during ~a" phase))))

(define (read-child process until read-result)
  (define result (box #f))
  (define reader
    (parameterize ([current-custodian (child-custody process)])
      (thread (lambda ()
                (with-handlers ([exn? (lambda (e) (set-box! result (cons #f e)))])
                  (set-box! result (cons #t (read-result (child-out process)))))))))
  (await! process reader until "stdout")
  (if (car (unbox result)) (cdr (unbox result)) (raise (cdr (unbox result)))))

(define (finish-child! process until)
  (await! process (child-proc process) until "process exit")
  (await! process (child-stderr-reader process) until "stderr")
  (unless (zero? (subprocess-status (child-proc process)))
    (child-error process (format "exited with status ~a" (subprocess-status (child-proc process))))))

;; Cleanup never waits without a bound, including a child that closed stdout
;; but stayed alive. The custodian closes all pipes and retires reader threads.
(define (stop-child! process [graceful? #f])
  (dynamic-wind
    void
    (lambda ()
      (define proc (child-proc process))
      (when (eq? (subprocess-status proc) 'running)
        (subprocess-kill proc (not graceful?))
        (unless (sync/timeout (if graceful? (stop-grace-seconds) 2) proc)
          (subprocess-kill proc #t)
          (sync/timeout 2 proc))))
    (lambda () (custodian-shutdown-all (child-custody process)))))

;; Startup owns cleanup before readiness, then transfers the live server to
;; bench-one. Stderr drains immediately, including before the readiness line.
(define (start-server backend suite port)
  (define process (spawn-child (format "~a/~a/server" backend suite) SERVER
                               backend suite HOST (number->string port)))
  (with-handlers ([exn? (lambda (e) (stop-child! process) (raise e))])
    (define until (deadline))
    (define ready
      (read-child process until
                  (lambda (out)
                    (let loop ()
                      (define line (read-line out))
                      (cond [(eof-object? line) #f]
                            [(regexp-match? #px"\"event\":\"ready\"" line) #t]
                            [else (loop)])))))
    (unless ready
      (finish-child! process until)
      (child-error process "server exited before ready"))
    (parameterize ([current-custodian (child-custody process)])
      (thread (lambda () (copy-port (child-out process) (open-output-nowhere)))))
    process))

;; One measurement owns the process until both its output and exit status are
;; known. All failure paths kill and reap it before returning to the server.
(define (with-client backend suite port mode n conns read-result)
  (define process (spawn-child (format "~a/~a/~a" backend suite mode) CLIENT
                               backend suite HOST (number->string port)
                               mode (number->string n) (number->string conns)))
  (dynamic-wind
    void
    (lambda ()
      (define until (deadline))
      (define result (read-child process until read-result))
      (finish-child! process until)
      (unless result (child-error process "no result"))
      result)
    (lambda () (stop-child! process))))

(define (run-client backend suite port mode n [conns 1])
  (with-client backend suite port mode n conns
               (lambda (out)
                 (for/fold ([result #f]) ([line (in-lines out)])
                   (if (and (not result) (regexp-match? #px"\"metric\"" line)) line result)))))

;; Sample a pid's RSS `n` times `dt` seconds apart and keep the minimum, the
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
  (define base 0)
  (define loaded 0)
  (define line
    (with-client backend suite port "connections" 0 conns
      (lambda (out)
        (for/fold ([result #f]) ([line (in-lines out)])
          (cond
            [(regexp-match? #px"\"event\":\"warmed\"" line)
             (set! base (sample-min-rss pid 4 0.1)) result]
            [(regexp-match? #px"\"metric\":\"connections\"" line)
             (set! loaded (sample-min-rss pid 12 0.15)) line]
            [else result])))))
  (values line base loaded))

;; Pull a "key":num or "key":"str" field out of an NDJSON line.
(define (jf line key)
  (define m (regexp-match (regexp (format "\"~a\":\"?([^,\"}]+)\"?" key)) line))
  (and m (cadr m)))

;; A failed measurement fails the run, rather than selecting a later success.
(define (bench-one suite backend)
  (define port (next-port!))
  (define process (start-server backend suite port))
  (define pid (subprocess-pid (child-proc process)))
  (with-handlers ([exn:fail? (lambda (e) (child-error process (exn-message e)))])
    (dynamic-wind void
      (lambda ()
        (sleep 0.3)
        (define lat (run-client backend suite port "latency" LAT-N))
        (define tput (run-client backend suite port "throughput" TPUT-N))
        ;; connections + memory: the client warms the accept path, the orchestrator
        ;; samples the baseline at the "warmed" marker and the loaded RSS during the
        ;; held-open measured batch. The throwaway warmup connections are held through
        ;; both samples, so they cancel in the delta.
        (define-values (conn-line base-rss loaded-rss) (run-connections backend suite port pid CONNS))
        ;; Client metrics do not excuse a server that died during the sample.
        ;; Drain its diagnostic under a deadline before accepting any results;
        ;; the intentional interrupt happens only in the cleanup below.
        (unless (eq? (subprocess-status (child-proc process)) 'running)
          (finish-child! process (deadline))
          (child-error process "server exited before sample commit"))
        (hash-set! results (list suite backend)
                   (list (cons 'p50 (jf lat "p50_ms"))
                         (cons 'p99 (jf lat "p99_ms"))
                         (cons 'p999 (jf lat "p999_ms"))
                         (cons 'rps (jf tput "rps"))
                         (cons 'conn_ms (jf conn-line "per_conn_ms"))
                         (cons 'base_rss base-rss)
                         (cons 'loaded_rss loaded-rss)
                         (cons 'per_conn_kb (real->decimal-string (/ (max 0 (- loaded-rss base-rss)) (max 1 CONNS)) 1)))))
      (lambda () (stop-child! process #t)))))

(module+ test-support
  (provide start-server stop-child! run-client run-connections bench-one
           child-timeout-seconds stop-grace-seconds))

(module+ main
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
     "glowcap vs Goblins, cross-implementation benchmark\n"
     (format "mode=~a suites=~a lat_n=~a tput_n=~a conns=~a\n\n"
             (if smoke? "smoke" "full") (string-join SUITES ",") LAT-N TPUT-N CONNS)
     (string-join (for/list ([s (in-list SUITES)]) (row s)) "\n\n")
     "\n"))

  (display report)
  (define out-dir (simplify-path (build-path repo-root "zig-out" "bench-reports")))
  (make-directory* out-dir)
  (define stamp (number->string (current-seconds)))
  (define mode-str (if smoke? "smoke" "full"))

  ;; Text report (terminal-friendly).
  (define txt-path (build-path out-dir (format "goblins-compare-~a.txt" stamp)))
  (call-with-output-file txt-path (lambda (o) (display report o)) #:exists 'replace)

  ;; SVG bar charts (self-contained, no JS), latency p50 and throughput.
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
)
