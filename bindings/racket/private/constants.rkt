#lang racket/base

;; Private ABI constants for the Racket pancake binding.
;;
;; The reflected integer families (return codes, reference and argument kinds,
;; codec, abort domains, the dial plan, and the caps) are generated into
;; `constants-gen.rkt` from the C ABI and re-provided here, so a value is
;; mirrored once and `zig build gen-binding-constants-check` rejects a stale
;; copy. This module adds the transport string symbols, which mirror
;; `model.transport` (a different authority, guarded by `meta-check`
;; name-presence) rather than a `pancake_*.h` value. HOST-ACTION-* lives in
;; `host-action-gen.rkt`.

(require "constants-gen.rkt")

(provide (all-from-out "constants-gen.rkt")
         FORWARD-CYCLE-MESSAGE HINT-DIRECT-ADDRESSES
         TRANSPORT-TCP TRANSPORT-KEYED-TCP TRANSPORT-INPROC TRANSPORT-IROH
         TRANSPORT-KEYED-RELAY TRANSPORT-WEBRTC
         provenance<-abi)

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
    [else 'unauthenticated]))

;; Cycle break message when a local Forward chain exceeds the hop cap.
(define FORWARD-CYCLE-MESSAGE "forward cycle: the local forward chain never terminates")
;; Locator hint name; mirrors model.transport.hint_direct_addresses.
(define HINT-DIRECT-ADDRESSES "direct-addresses")
;; OCapN transport symbols; mirrors model.transport.*.
(define TRANSPORT-TCP "tcp")
(define TRANSPORT-KEYED-TCP "keyed-tcp")
(define TRANSPORT-INPROC "inproc")
(define TRANSPORT-IROH "iroh")
(define TRANSPORT-KEYED-RELAY "keyed-relay")
(define TRANSPORT-WEBRTC "webrtc")
