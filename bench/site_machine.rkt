#lang racket/base
;; Where and when a site bench runs: on the fast core cluster, once the machine
;; is quiet. site_report.rkt runs every bench through `run` or `run-command`,
;; and site_report-test.rkt drives `quiet` with a fake load and clock.
(require racket/string racket/format racket/system racket/file racket/future)
(provide fast-cores run run-command quiet)

;; The cores that share the highest maximum clock when two or more do, lowest
;; number first, and empty otherwise. On a mixed-core machine the scheduler may
;; place an unpinned bench on a slow core, and the figure follows the core it
;; drew. One core cannot hold a two-thread row.
(define (fast-cluster)
  (define cpus
    (for*/list ([d (in-list (directory-list "/sys/devices/system/cpu"))]
                [m (in-value (regexp-match #px"^cpu(\\d+)$" (path->string d)))]
                #:when m
                [f (in-value (build-path "/sys/devices/system/cpu" d "cpufreq/cpuinfo_max_freq"))]
                #:when (file-exists? f))
      (cons (string->number (cadr m)) (string->number (string-trim (file->string f))))))
  (define top (if (null? cpus) 0 (apply max (map cdr cpus))))
  (define fast (sort (for/list ([c (in-list cpus)] #:when (= (cdr c) top)) (car c)) <))
  (if (>= (length fast) 2) fast '()))

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
