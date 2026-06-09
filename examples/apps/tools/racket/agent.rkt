#lang racket/base
;; An agent, written on pancake actors in native Racket. It connects to the tools
;; coordinator (which may be written in any language) and proves the three
;; capability properties — delegation, attenuation, revocation — over the wire.
;;
;;   racket agent.rkt 127.0.0.1 9099 rkt-agent

(require "../../../../bindings/racket/pancake.rkt")

;; Send a request and drive the connection until it settles, returning
;; `(cons 'ok value)` or `(cons 'broken message)`. Single-threaded, matching the
;; rest of the binding.
(define (try-call c target verb . args)
  (define result (box 'pending))
  (with-vat (conn-vat c)
    (define vow (apply <- target verb args))
    (on vow
        (lambda (v) (set-box! result (cons 'ok v)))
        #:catch (lambda (m) (set-box! result (cons 'broken m)))))
  (async-flush! (conn-async c))
  (let loop ()
    (define r (unbox result))
    (cond
      [(eq? r 'pending)
       (define ev (async-next-event (conn-async c)))
       (when (eof-object? ev) (error 'try-call "connection closed before ~a settled" verb))
       (vat-serve! (conn-vat c) ev)
       (loop)]
      [else r])))

(define (run host port nick)
  (define (check label ok)
    (printf "~a: ~a — ~a\n" nick (if ok "ok" "FAIL") label)
    (flush-output)
    (unless ok (exit 1)))

  (define c (connect host port))
  (define tools (fetch c "tools"))

  ;; 1. Delegation: get a clock capability and call it.
  (define clock (cdr (try-call c tools 'grant "clock")))
  (define now (try-call c clock 'now))
  (check "delegation: was handed a clock and called it"
         (and (eq? (car now) 'ok) (exact-integer? (cdr now))))

  ;; 2. Attenuation: a read-only file capability reads but refuses writes.
  (define files (cdr (try-call c tools 'grant "files-readonly")))
  (define rd (try-call c files 'read "report.txt"))
  (check "attenuation: read through the read-only view"
         (and (eq? (car rd) 'ok) (string? (cdr rd))))
  (check "attenuation: write is refused"
         (eq? (car (try-call c files 'write "report.txt" "tampered")) 'broken))

  ;; 3. Revocation: a revocable handle works, then breaks after revoke.
  (define rclock (cdr (try-call c tools 'grant-revocable "clock")))
  (check "revocation: the handle works before revoke"
         (eq? (car (try-call c rclock 'now)) 'ok))
  (try-call c tools 'revoke-last)
  (check "revocation: the handle breaks after revoke"
         (eq? (car (try-call c rclock 'now)) 'broken))

  (printf "~a: all capability properties held\n" nick)
  (flush-output)
  (connection-close! c))

(module+ main
  (define args (current-command-line-arguments))
  (when (< (vector-length args) 3)
    (eprintf "usage: agent.rkt <host> <port> <nick>\n")
    (exit 2))
  (define host (vector-ref args 0))
  (define port (string->number (vector-ref args 1)))
  (define nick (vector-ref args 2))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (eprintf "agent ~a failed: ~a\n" nick (if (exn? e) (exn-message e) e))
                     (exit 1))])
    (run host port nick)
    (exit 0)))
