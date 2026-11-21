#lang racket/base
;; Where and when a site bench runs: on the fast cores of one cache cluster,
;; once the machine is quiet. site_report.rkt runs every bench through `run` or
;; `run-command`, and site_report-test.rkt drives `quiet` with a fake load and
;; clock and `fast-cores-sharing-a-cache` with fake topologies.
(require racket/string racket/format racket/system racket/file racket/future racket/list)
(provide fast-cores fast-cores-sharing-a-cache run run-command quiet)

;; The cores a bench may use, from rows of (core max-clock cache), where cache
;; names the core's last-level cache and #f means unknown: the cores at the
;; highest maximum clock that share one last-level cache, the cache holding the
;; most of them, lowest core first. Empty when fewer than two qualify.
;;
;; Both halves change the figures. On a mixed-core machine the scheduler may
;; place an unpinned bench on a slow core, and the figure follows the core it
;; drew. And when the fast cores sit in two clusters with separate caches, a
;; bench whose threads land in both pays for every wake across them, so the
;; figure follows which clusters its threads drew. One core cannot hold a
;; two-thread row.
(define (fast-cores-sharing-a-cache rows)
  (define top (if (null? rows) 0 (apply max (map cadr rows))))
  (define fast (filter (lambda (r) (= (cadr r) top)) rows))
  (define groups (group-by caddr fast))
  (define widest
    (for/fold ([best '()]) ([g (in-list groups)])
      (define cores (sort (map car g) <))
      (if (or (> (length cores) (length best))
              (and (= (length cores) (length best)) (pair? cores) (< (car cores) (car best))))
          cores
          best)))
  (if (>= (length widest) 2) widest '()))

;; This machine's rows for `fast-cores-sharing-a-cache`, read from sysfs. A
;; core's last-level cache is the shared-core list of its highest cache level.
(define (machine-cores)
  (define root "/sys/devices/system/cpu")
  (define (read-trimmed f) (and (file-exists? f) (string-trim (file->string f))))
  (define (last-level-cache cpu-dir)
    (define dir (build-path cpu-dir "cache"))
    (define levels
      (if (directory-exists? dir)
          (for*/list ([d (in-list (directory-list dir))]
                      #:when (regexp-match? #px"^index\\d+$" (path->string d))
                      [level (in-value (read-trimmed (build-path dir d "level")))]
                      [shared (in-value (read-trimmed (build-path dir d "shared_cpu_list")))]
                      #:when (and level shared))
            (cons (string->number level) shared))
          '()))
    (and (pair? levels) (cdr (argmax car levels))))
  (for*/list ([d (in-list (directory-list root))]
              [m (in-value (regexp-match #px"^cpu(\\d+)$" (path->string d)))]
              #:when m
              [clock (in-value (read-trimmed (build-path root d "cpufreq/cpuinfo_max_freq")))]
              #:when clock)
    (list (string->number (cadr m)) (string->number clock) (last-level-cache (build-path root d)))))

(define (fast-cluster) (fast-cores-sharing-a-cache (machine-cores)))

;; The two cores a pinned row names: the first two of the fast cluster, or
;; cores 0 and 1 when there is no cluster.
(define (fast-cores)
  (define fast (fast-cluster))
  (if (null? fast) (list 0 1) (list (car fast) (cadr fast))))

;; The prefix that keeps a bench and the build that runs it on the fast
;; cluster. Empty when there is no cluster.
(define (cluster-prefix)
  (define fast (fast-cluster))
  (if (null? fast) "" (format "taskset -c ~a " (string-join (map number->string fast) ","))))

;; Start a bench only once the machine is quiet: its one-minute load is under
;; a quarter of its logical CPUs, and at least 1. Load counts the whole
;; machine, so a build in another checkout or a neighbor on a shared host
;; keeps it high, and that work would land in the page's figures. The wait
;; prints the load once a minute and refuses after QUIET-DEADLINE seconds,
;; because a machine that stays busy cannot produce figures worth publishing.
;; A machine without /proc/loadavg starts at once.
(define QUIET-DEADLINE 600)
(define QUIET-POLL 20)
(define (quiet-limit cpus) (max 1 (/ cpus 4)))
(define (machine-load)
  (and (file-exists? "/proc/loadavg")
       (string->number (car (string-split (file->string "/proc/loadavg"))))))
(define (quiet #:load [load machine-load] #:cpus [cpus (processor-count)] #:pause [pause sleep]
               #:say [say (lambda (line) (printf "  ~a\n" line) (flush-output))])
  (define limit (quiet-limit cpus))
  (let loop ([waited 0])
    (define now (load))
    (cond
      [(or (not now) (< now limit)) (void)]
      [(>= waited QUIET-DEADLINE)
       (error 'site-report "machine load stayed at or above ~a for ~a minutes (last ~a). Stop the other work on this machine, or run on a quieter one, then rerun"
              (~r limit #:precision 1) (quotient QUIET-DEADLINE 60) (~r now #:precision 1))]
      [else
       (when (zero? (modulo waited 60))
         (say (format "waiting for a quiet machine: load ~a, starting under ~a" (~r now #:precision 1) (~r limit #:precision 1))))
       (pause QUIET-POLL)
       (loop (+ waited QUIET-POLL))])))

;; Run one bench command under the cluster prefix and return what it printed.
(define (run bench) (run-command (string-append (cluster-prefix) bench)))

;; Run one command as given, once the machine is quiet, and return what it
;; printed. `system` returns #f on a non-zero exit without raising, so the
;; check here keeps a failed bench from leaving the page half-freshened with a
;; stale goblins or langs report.
(define (run-command cmd)
  (quiet)
  (printf "  $ ~a\n" cmd) (flush-output)
  (define out (open-output-string))
  (define ok (parameterize ([current-output-port out]
                            [current-error-port out])
               (system cmd)))
  (define text (get-output-string out))
  (display text)
  (unless ok (error 'site-report "command failed: ~a" cmd))
  text)
