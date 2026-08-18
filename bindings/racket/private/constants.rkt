#lang racket/base

;; Private ABI constants for the Racket pancake binding.
;;
;; The reflected integer families (return codes, reference and argument kinds,
;; codec, abort domains, the dial plan, and the caps) are generated into
;; `constants-gen.rkt` from the C ABI and re-provided here, so a value is
;; mirrored once and `zig build gen-binding-constants-check` rejects a stale
;; copy. Transport and locator-hint strings are generated there from
;; `model.transport`. HOST-ACTION-* lives in `host-action-gen.rkt`.

(require "constants-gen.rkt")

(provide (all-from-out "constants-gen.rkt")
         FORWARD-CYCLE-MESSAGE
         provenance<-abi
         lifecycle-closed?)

;; The ADR-0097 provenance symbol for one reflected ABI value.
;;
;; It lives beside the constants it reads because two surfaces report the
;; same fact about the same partner — a session's partner identity
;; and the live trace's session-open — and `trace.rkt` sits below the session
;; structs, so neither can reach a copy kept in the other. One answer, one
;; spelling.
(define (provenance<-abi raw)
  (cond
    [(= raw DURABLE-PROVENANCE-AUTHENTICATED-TRANSPORT) 'authenticated-transport]
    [(= raw DURABLE-PROVENANCE-UNAUTHENTICATED) 'unauthenticated]
    [else (error 'pancake "ABI returned unknown durable provenance: ~a" raw)]))

;; A future/corrupted lifecycle word is not ordinary unfinished progress: that
;; interpretation would park forever waiting for a state this ABI cannot name.
(define (lifecycle-closed? raw)
  (cond
    [(or (= raw LIFECYCLE-ACTIVE)
         (= raw LIFECYCLE-FINISHING)
         (= raw LIFECYCLE-TERMINATING)) #f]
    [(= raw LIFECYCLE-CLOSED) #t]
    [else (error 'pancake "ABI returned unknown lifecycle state: ~a" raw)]))

;; Cycle break message when a local Forward chain exceeds the hop cap.
(define FORWARD-CYCLE-MESSAGE "forward cycle: the local forward chain never terminates")

(module+ test
  (require rackunit)
  (check-false (lifecycle-closed? LIFECYCLE-ACTIVE))
  (check-true (lifecycle-closed? LIFECYCLE-CLOSED))
  (check-exn exn:fail? (lambda () (lifecycle-closed? #xffffffff)))
  (check-exn exn:fail? (lambda () (provenance<-abi #xffffffff))))
