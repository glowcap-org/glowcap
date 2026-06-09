#lang racket
;; Live interop proof for the Racket binding: a peer built on `libpancake`'s C
;; ABI holds a *keyed* OCapN conversation with a real Spritely Goblins vat over
;; TCP — driven through the *same* `connect`/`fetch` application surface the
;; cross-language demos use, so what is proven against a real Goblins vat is the
;; application API itself, not a bespoke handshake script.
;;
;; It spawns the conformance Goblins host, learns the echo cap's swiss-num from
;; its NDJSON readiness line, then `connect` (which completes the keyed
;; `op:start-session` handshake), `fetch` the echo cap, and calls it positionally
;; — asserting Goblins resolves it. The positional call uses `peer-send-deliver!`
;; because Goblins invokes a cap with no method symbol, which the `<-` verb form
;; cannot express. Needs `racket` plus the `goblins` collection on PATH; run via
;; `zig build racket-goblins-interop`.

(require racket/tcp
         "../../bindings/racket/pancake.rkt")

(define HOST "127.0.0.1")
(define PORT 22095)
(define RACKET "/usr/local/bin/racket")
(define HOST-SCRIPT "conformance/goblins-peer/racket/goblins-host.rkt")

(define (fail msg)
  (eprintf "racket-goblins-interop FAILED: ~a\n" msg)
  (exit 1))

(define (read-swiss port)
  (let loop ()
    (define line (read-line port))
    (cond
      [(eof-object? line) (fail "goblins exited before publishing the echo cap")]
      [(regexp-match #px"\"swiss\":\"([^\"]+)\"" line) => cadr]
      [else (loop)])))

(define (await-resolve ac answer who)
  (let loop ()
    (define ev (async-next-event ac))
    (cond
      [(eof-object? ev) (fail (format "connection closed before ~a resolved" who))]
      [(and (resolve-event? ev) (= (resolve-event-answer ev) answer))
       (define res (resolve-event-resolution ev))
       (if (fulfill? res)
           (fulfill-value res)
           (fail (format "~a broke: ~a" who (brk-message res))))]
      [else (loop)])))

(define-values (proc proc-out proc-in proc-err)
  (subprocess #f #f #f RACKET HOST-SCRIPT HOST (number->string PORT)))

(with-handlers ([(lambda (_) #t) (lambda (e) (subprocess-kill proc #t) (raise e))])
  (define swiss (read-swiss proc-out))
  (printf "racket-goblins-interop: goblins published echo swiss=~a on ~a:~a\n" swiss HOST PORT)

  ;; `connect` completes the keyed handshake; reaching the fetch means Goblins
  ;; accepted our signed start-session and we accepted its.
  (define conn (connect HOST PORT))
  (printf "racket-goblins-interop: session open, keyed start-session accepted by goblins\n")

  (define echo (fetch conn swiss))
  (printf "racket-goblins-interop: fetched goblins echo cap, calling it\n")

  ;; Call echo positionally — Goblins invokes a cap with no method symbol.
  (peer-send-deliver! (conn-peer conn) echo (list #"pancake-ping") #:answer 2000)
  (async-flush! (conn-async conn))
  (await-resolve (conn-async conn) 2000 "echo")

  (printf "racket-goblins-interop OK: keyed handshake + bootstrap fetch + echo deliver/resolve with live Goblins\n")
  (connection-close! conn)
  (subprocess-kill proc #t))
