#lang racket/base
;; glowcap-break-call.rkt — a Goblins client that observes a glowcap break.
;;
;; It dials a glowcap listener over TCP and enlivens a swiss-num the glowcap
;; peer never registered. glowcap auto-serves the bootstrap fetch with a break
;; ("unknown swissnum"), which on the V1.0 wire is a resolver-callback deliver
;; carrying `['break, reason-symbol]`. The proof is that this client's vow
;; *breaks with that reason* — Goblins' unmarshaller accepted the payload —
;; rather than the session dying on an unknown record tag (the failure mode of
;; an `<error …>` record payload, which Goblins' unmarshal table does not know
;; and rejects with `captp-unknown-record-rag`, surfacing here as a timeout or
;; a severed-session error instead of the reason).
;;
;; Usage:
;;   racket glowcap-break-call.rkt <target-port> <swiss-ascii> [local-port]
;;
;; Prints `BREAK OK: <err>` and exits 0 when the vow breaks with the glowcap
;; reason; `BREAK WRONG-REASON: <err>`, `BREAK ERR: fulfilled`, or
;; `BREAK TIMEOUT` and exits 1 otherwise.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         racket/async-channel)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))
(define target-port (string->number (vector-ref argv 0)))
(define swiss-ascii (vector-ref argv 1))
;; Goblins binds its own port so the listener can return calls to it.
(define local-port
  (if (>= (vector-length argv) 3)
      (string->number (vector-ref argv 2))
      19997))

;; Settled outside the vat so the outer thread can `sync/timeout` on it without
;; blocking the vat that has to deliver the resolution.
(define response-ch (make-async-channel))
(define dialer-vat (make-vat))

(dialer-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" local-port))
   (define mycapn (spawn-mycapn netlayer))

   (define target
     (ocapn-sturdyref
      (ocapn-node 'tcp (format "127.0.0.1:~a" target-port) #f)
      (string->bytes/latin-1 swiss-ascii)))

   (on (<- mycapn 'enliven target)
       (lambda (actor)
         (async-channel-put response-ch `(fulfilled ,actor)))
       #:catch
       (lambda (err) (async-channel-put response-ch `(broken ,err))))))

(define reply (sync/timeout 10.0 response-ch))
(case (and (pair? reply) (car reply))
  [(broken)
   (define err (cadr reply))
   (define rendered (format "~a" err))
   (cond
     [(regexp-match? #rx"unknown swissnum" rendered)
      (printf "BREAK OK: ~v~n" err)
      (exit 0)]
     [else
      ;; Broken, but not with glowcap's reason, e.g. a severed session after
      ;; an unmarshal failure. That is the bug this scenario exists to catch.
      (printf "BREAK WRONG-REASON: ~v~n" err)
      (exit 1)])]
  [(fulfilled)
   (printf "BREAK ERR: fulfilled~n")
   (exit 1)]
  [else
   (printf "BREAK TIMEOUT~n")
   (exit 1)])
