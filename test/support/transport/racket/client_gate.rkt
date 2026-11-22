#lang racket
;; The gate protocol a Racket live client speaks: fail a named gate, read a
;; readiness field from the partner's stdout, parse or ignore the port argument,
;; and run the accept loop.

(provide fail read-swiss read-sturdyref-path await-greeter-ready parse-port ignore-port-args start-accept-loop)

(define (fail gate msg)
  (eprintf "~a FAILED: ~a\n" gate msg)
  (exit 1))

(define (read-swiss in [miss "never saw the readiness line"])
  (read-readiness-field in "swiss" miss))

(define (read-sturdyref-path in [miss "never saw the sturdyref path readiness field"])
  (read-readiness-field in "sturdyref-path" miss))

(define (read-readiness-field in field miss)
  (cadr (read-ready-line in (pregexp (format "\"~a\":\"([^\"]+)\"" (regexp-quote field))) miss)))

(define (await-greeter-ready in [miss "never saw the exporter's greeter readiness line"])
  (void (read-ready-line in #rx"\"name\":\"greeter\"" miss)))

;; How long a partner has to print its readiness line: under the step's 30 s process deadline, so the gate names the miss before the build stops it.
(define ready-seconds 20)

;; Read the partner's stdout until a line matches `rx`. The deadline bounds the
;; whole wait, including a read the partner never answers.
(define (read-ready-line in rx miss)
  (define deadline (+ (current-inexact-milliseconds) (* 1000 ready-seconds)))
  (let loop ()
    (define left (/ (max 0 (- deadline (current-inexact-milliseconds))) 1000.0))
    (define line (sync/timeout left (read-line-evt in)))
    (cond
      [(not line) (fail "interop" (format "~a within ~a s" miss ready-seconds))]
      [(eof-object? line) (fail "interop" (format "~a: its output closed" miss))]
      [(regexp-match rx line) => values]
      [else (loop)])))

(define (ignore-port-args gate)
  (for ([arg (vector->list (current-command-line-arguments))])
    (unless (regexp-match? #px"^--port=" arg)
      (fail gate (format "unknown argument ~a" arg)))))

(define (parse-port gate default [max-port 65535])
  (let loop ([args (vector->list (current-command-line-arguments))])
    (cond
      [(null? args) default]
      [(regexp-match #px"^--port=(\\d+)$" (car args))
       => (lambda (m)
            (define p (string->number (cadr m)))
            (unless (<= 1 p max-port)
              (eprintf "~a: --port must be an integer in 1..~a\n" gate max-port)
              (exit 2))
            p)]
      [else
       (eprintf "~a: unknown argument ~a\n" gate (car args))
       (exit 2)])))

(define (start-accept-loop accept-one!)
  (thread
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_) (void))])
       (let loop ()
         (accept-one!)
         (loop))))))
