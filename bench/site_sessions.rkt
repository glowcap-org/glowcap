#lang racket/base
;; Completed live-session barriers and session-opening timings for the site.
;; site_report.rkt owns execution and splicing; these functions only parse/render.
(require racket/list racket/string racket/format "site_chart.rkt")
(provide parse-live sessions-region)

(define (parse-live out)
  (define rows
    (for/list ([m (regexp-match* #px"peer_scaling phase2 n=(\\d+) ok=true live=(\\d+) shards=(\\d+) server_rss_kb_before=(\\d+) server_rss_kb_after=(\\d+) server_rss_delta_kb=(\\d+) client_rss_kb=(\\d+) elapsed_ms=(\\d+)"
                                out #:match-select values)])
      (define row (map string->number (cdr m)))
      (unless (and (positive? (car row)) (= (car row) (cadr row))
                   (>= (list-ref row 4) (list-ref row 3))
                   (= (- (list-ref row 4) (list-ref row 3)) (list-ref row 5)))
        (error 'site-sessions "inconsistent completed-session row"))
      row))
  (unless (equal? (map car rows) '(1000 10000 50000 100000 500000))
    (error 'site-sessions "capacity report requires every completed barrier through 500000"))
  rows)

(define (sessions-region live opens table stamp)
  (string-append
   stamp
   "\n<p class=\"bench-note\">Cleartext loopback TCP with signed CapTP handshakes and a bootstrap fetch on every connection. All sessions remain open at the RSS sample. The server uses 32 HostRuntime shards. A separate raw-peer process supplies load. The run uses an isolated Linux user/network namespace and a descriptor limit of 524288. Linux chooses io_uring or epoll at runtime. RSS excludes kernel socket memory. These are capacity and barrier measurements, not WAN latency or sealed-channel capacity.</p>\n"
   (table '("live sessions" "server baseline KiB" "server loaded KiB" "server delta KiB/session" "load process KiB" "barrier seconds")
          (for/list ([r (in-list live)])
            (list (commas (car r)) (commas (list-ref r 3)) (commas (list-ref r 4))
                  (~r (/ (list-ref r 5) (car r)) #:precision 2)
                  (commas (list-ref r 6)) (~r (/ (list-ref r 7) 1000) #:precision 3))))
   "\n<p class=\"bench-note\">Session opening includes connect, handshake, bootstrap fetch, and close. Each transport runs separately without CPU pinning. The table reports measured latency, without treating signing and handshake primitives as a complete cost model.</p>\n"
   (table '("transport" "open p50 µs" "open p99 µs" "open mean µs")
          (for/list ([transport '("tcp" "noise-tcp")])
            (define r (hash-ref opens (string-append transport ":session-open")))
            (cons transport
                  (for/list ([key '(p50 p99 mean)])
                    (~r (/ (hash-ref r key) 1000) #:precision 2)))))))
