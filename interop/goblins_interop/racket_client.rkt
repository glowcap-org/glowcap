#lang racket
;; Live interop proof for the Racket binding: a peer built on `libpancake`'s C
;; ABI holds a *keyed* OCapN conversation with a real Spritely Goblins vat over
;; TCP — driven through the *same* `connect`/`enliven`/`send` application surface
;; the cross-language demos use, so what is proven against a real Goblins vat is
;; the application API itself, not a bespoke handshake script.
;;
;; It spawns the conformance Goblins host, learns the echo cap's swiss-num from
;; its NDJSON readiness line, then `connect` (keyed `op:start-session`),
;; `enliven` the echo sturdyref (bootstrap fetch + ADR-0012 dedup), calls it
;; positionally, then a repeat `enliven` of the same swiss-num. Positional calls
;; pass the empty method symbol to `session-send`. Needs `racket` + `goblins`;
;; `zig build racket-goblins-interop`.

(require "../../bindings/racket/pancake.rkt"
         "../_common/racket/helpers.rkt")

(define HOST "127.0.0.1")
(define PORT (parse-port "racket-goblins-interop" 22095))
(define RACKET "/usr/local/bin/racket")
(define HOST-SCRIPT "conformance/goblins-peer/racket/goblins-host.rkt")

(define-values (proc proc-out proc-in proc-err)
  (subprocess #f #f #f RACKET HOST-SCRIPT HOST (number->string PORT)))

(with-handlers ([(lambda (_) #t) (lambda (e) (subprocess-kill proc #t) (raise e))])
  (define swiss (read-swiss proc-out "goblins exited before publishing the echo cap"))
  (printf "racket-goblins-interop: goblins published echo swiss=~a on ~a:~a\n" swiss HOST PORT)

  (define conn (connect (tcp-locator HOST PORT)))
  (printf "racket-goblins-interop: session open, keyed start-session accepted by goblins\n")

  (define sturdyref (string-append "ocapn://goblins-echo.tcp/s/" swiss))
  (define echo (session-enliven conn sturdyref))
  (printf "racket-goblins-interop: enlivened goblins echo cap, calling it\n")

  (session-send conn echo (string->symbol "") #"pancake-ping")

  (define again (session-enliven conn sturdyref))
  (unless (and (far-ref? echo) (far-ref? again)
               (= (far-ref-id echo) (far-ref-id again)))
    (error 'racket-goblins-interop
           "repeat enliven did not return the same far import (dedup miss)"))
  (session-send conn again (string->symbol "") #"pancake-ping-again")
  (printf "racket-goblins-interop: repeat enliven same import (dedup), second call resolved\n")

  (printf "racket-goblins-interop OK: keyed handshake + enliven/dedup + echo deliver/resolve with live Goblins\n")
  (session-close! conn)
  (subprocess-kill proc #t))
