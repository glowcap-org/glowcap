#lang racket
;; Shared helpers for Racket interop client scripts.

(provide fail read-swiss await-greeter-ready parse-port ignore-port-args start-accept-loop)

(define (fail gate msg)
  (eprintf "~a FAILED: ~a\n" gate msg)
  (exit 1))

(define (read-swiss in [miss "never saw the readiness line"])
  (let loop ()
    (define line (read-line in))
    (cond
      [(eof-object? line) (fail "interop" miss)]
      [(regexp-match #px"\"swiss\":\"([^\"]+)\"" line) => cadr]
      [else (loop)])))

(define (await-greeter-ready in [miss "never saw the exporter's greeter readiness line"])
  (let loop ()
    (define line (read-line in))
    (cond
      [(eof-object? line) (fail "interop" miss)]
      [(regexp-match? #rx"\"name\":\"greeter\"" line) (void)]
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
