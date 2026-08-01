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
;; pass the empty method symbol to `session-send`. It closes by pipelining
;; `session-get` against a call answer Goblins settles to a Struct, the one
;; shape a field projects out of. Needs `racket` + `goblins`;
;; `zig build racket-goblins-interop`.

(require "../../bindings/racket/pancake.rkt"
         "../_common/racket/helpers.rkt")

(define HOST "127.0.0.1")
(define PORT (parse-port "racket-goblins-interop" 22095))
(define RACKET
  (or (find-executable-path "racket")
      (error 'racket-client "racket executable not found on PATH")))
(define HOST-SCRIPT "conformance/goblins-peer/racket/goblins-host.rkt")
;; The Struct-returning record cap goblins-host.rkt publishes for the `op:get`
;; leg, at the swiss-num it hardcodes (the echo cap owns the NDJSON `swiss` line).
(define RECORD-SWISS "pancakeRecordSwissnumABCDEF12345")

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

  ;; The echo actor is `(lambda args args)`: it returns its argument list, so
  ;; assert the content survived the round-trip (the native driver's bar).
  (define (assert-echoed reply expected)
    (unless (equal? reply (list expected))
      (error 'racket-goblins-interop
             "echo returned ~v, expected ~v" reply (list expected))))
  (assert-echoed (session-send conn echo (string->symbol "") #"pancake-ping")
                 #"pancake-ping")

  (define again (session-enliven conn sturdyref))
  (unless (and (ref? echo) (ref? again)
               (= (ref-id echo) (ref-id again)))
    (error 'racket-goblins-interop
           "repeat enliven did not return the same Host identity (dedup miss)"))
  (assert-echoed (session-send conn again (string->symbol "") #"pancake-ping-again")
                 #"pancake-ping-again")
  (printf "racket-goblins-interop: repeat enliven same Host identity (dedup), second call resolved\n")

  ;; `session-get` pipelines an `op:get` against a still-pending answer, and a
  ;; field only projects out of an OCapN Struct. No binding can build one,
  ;; because the C ABI carries no Struct argument, so the record cap
  ;; `goblins-host.rkt` publishes for this leg is the only peer that hands one
  ;; back. Both projections are minted before either is awaited, so each rides
  ;; the unsettled call answer and the two differing values pin which field was
  ;; asked for.
  (define record (session-fetch conn RECORD-SWISS))
  (define made (session-send-promise conn record (string->symbol "") "pancake-get"))
  (define name-vow (session-get conn made "name"))
  (define kind-vow (session-get conn made "kind"))
  (define (assert-projected vow field expected)
    (define got (session-await conn vow))
    (unless (equal? got expected)
      (error 'racket-goblins-interop
             "op:get on ~v projected ~v, expected ~v" field got expected)))
  (assert-projected name-vow "name" "pancake-get")
  (assert-projected kind-vow "kind" "record")
  (printf "racket-goblins-interop: op:get projected name and kind out of goblins' Struct reply\n")

  (printf "racket-goblins-interop OK: keyed handshake + enliven/dedup + echo deliver/resolve with live Goblins\n")
  (session-close! conn)
  (subprocess-kill proc #t))
