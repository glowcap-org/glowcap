#lang racket/base
;; host-support.rkt: what the Goblins host scripts in this directory print and
;; publish alike.
;;
;; Every host announces itself to its Zig driver the same way: one NDJSON line
;; per readiness event on stdout. Four of them publish the same echo cap at the
;; OCapN conformance suite's canonical swiss-num, and the two iroh scripts
;; print the same `SESSION` line for a session their netlayer opens. A host
;; keeps what is its own, its `^greeter` and its swiss-nums, and requires the
;; rest from here.

(require racket/string)

(provide emit-ndjson
         ECHO-SWISS-NUM
         ^echo
         report-session)

;; Emit one JSON object per line and flush it, so the driver reads each
;; readiness event as it happens whatever the port's buffer mode. `event-fields`
;; is an assoc list of (key . string-value). The JSON is hand-rolled to avoid
;; pulling in another package for this: keys are static and values are
;; controlled, so quote and backslash are the only characters escaped.
(define (emit-ndjson event-fields)
  (define (escape s) (regexp-replace* #px"[\\\\\"]" s "\\\\\\0"))
  (define pairs
    (for/list ([f event-fields])
      (format "\"~a\":\"~a\"" (car f) (escape (cdr f)))))
  (printf "{\"v\":1,~a}~n" (string-join pairs ","))
  (flush-output))

;; The OCapN conformance suite's canonical echo swiss-num, the one
;; `seven-caps-peer.rkt` and glowcap's conformance peer also register.
(define ECHO-SWISS-NUM
  (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))

;; Echo behavior: `(lambda args args)` answers with its arguments unchanged.
(define (^echo _bcom)
  (lambda args
    args))

;; A session-trace sink that prints what a netlayer saw at the wire, so the
;; process on the other end can read back what this end believes about the
;; session. An accepted iroh connection carries the dialer's endpoint id, the
;; one QUIC authenticated on the way in, so a hello claiming that same id
;; reports its provenance as an authenticated transport identity, and a hello
;; claiming anything else stays unproven.
(define (report-session event _handle info)
  (when (eq? event 'open)
    (printf "SESSION transport=~a provenance=~a partner=~a session-id=~a~n"
            (hash-ref info 'transport)
            (hash-ref info 'durable-provenance)
            (hash-ref info 'partner-designator)
            (hash-ref info 'session-id))))
