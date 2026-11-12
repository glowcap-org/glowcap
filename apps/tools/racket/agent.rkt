#lang racket/base
;; An agent, written on glowcap actors in native Racket. It connects to the tools
;; coordinator (which may be written in any language) and proves the three
;; capability properties — delegation, attenuation, revocation — over the wire.
;;
;;   racket agent.rkt <locator> rkt-agent
;;
;; The locator is the `ocapn://` URI the coordinator printed.

(require "../../_demo/bindings.rkt"
         "../../_demo/tools_check.rkt"
         "../../../bindings/racket/glowcap-tcp.rkt"
         ;; The public module raises exn:fail:glowcap with its code but does
         ;; not provide the code's name.
         (only-in "../../../bindings/racket/private/constants.rkt" ERR-BROKEN))

;; `session-send`, summarized for the checks below: `(cons 'ok value)` on a
;; fulfilled reply, `(cons 'broken message)` on a broken one (revocation tests
;; expect broken outcomes, so they are data here, not errors). Any other
;; failure, a transport or marshalling one, propagates with its own cause.
(define (broken? e)
  (and (exn:fail:glowcap? e) (= (exn:fail:glowcap-code e) ERR-BROKEN)))
(define (try-call c target verb . args)
  (with-handlers ([broken? (lambda (e) (cons 'broken (exn-message e)))])
    (cons 'ok (apply session-send c target verb args))))

(define (run locator nick)
  (define check (make-check nick))

  (define runtime (open-runtime
                  #:providers
                  (list (tcp-provider))))
  (define c (runtime-connect runtime (parse-locator locator)))
  (define tools (session-fetch c "tools"))

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
  (session-close! c)
  (runtime-close! runtime))

(module+ main
  (define args (current-command-line-arguments))
  (when (< (vector-length args) 2)
    (eprintf "usage: agent.rkt <locator> <nick>\n")
    (exit 2))
  (define locator (vector-ref args 0))
  (define nick (vector-ref args 1))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (eprintf "agent ~a failed: ~a\n" nick (if (exn? e) (exn-message e) e))
                     (exit 1))])
    (run locator nick)
    (exit 0)))
