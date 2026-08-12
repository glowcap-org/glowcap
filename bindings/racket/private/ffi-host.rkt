#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for the `pancake_host_*` byte-fed
;; host family (ADR-0072), loaded from its own libpancake_host archive.
;;
;; Nothing here is public. The shared frame, argument, reference, and
;; last-abort layouts stay in `ffi-shared.rkt`. The host surface
;; spans `private/host.rkt`, `private/session.rkt`, `private/action.rkt`,
;; and `private/pump.rkt`.
;;
;; Callback discipline: the behavior callback fires synchronously on the
;; Racket thread executing the enclosing `pancake_host_*` call, so a plain
;; `_fun` callback type is correct — no `#:async-apply`. A trampoline stays
;; alive only while its Racket closure does, so every behavior closure
;; registered with the host is retained in the host's strong `keep` table
;; (`private/host.rkt`) until the host dies. Settlements carry no callback at
;; all: they ride the action queue as SETTLE/FAIL and the drain routes them by
;; vow id (`private/action.rkt` + `private/promise.rkt`).
;;
;; The bound functions and their out-cell wrappers are generated from the
;; archive's annotated symbol inventory (`ffi-host-gen.rkt`, `zig build
;; gen-binding-racket-ffi`); the callback types and the plan/dial cstructs
;; live in `ffi-shared.rkt`, the binding's types leaf. This module owns the
;; prose, the one bespoke wrapper below, and the re-provides. Every C
;; out-param is a fresh caller-owned cell inside a generated or bespoke
;; wrapper; star-suffixed raw stubs stay unprovided. Callers see
;; `(values rc …)` only.
(require ffi/unsafe
         "constants.rkt"
         "ffi-host-gen.rkt"
         "ffi-shared.rkt")
(provide (except-out (all-from-out "ffi-host-gen.rkt")
                     pancake_host_pending_dial*)
         (all-from-out "ffi-shared.rkt")
         pancake_host_pending_dial)

;; Borrow the complete pending locator for `ticket`. The C call projects its
;; hint array into caller-owned storage, so retry with the required count and
;; return the live view for an immediate `pancake_locator_clone`. Bespoke rather
;; than generated because one output's capacity controls the other output's
;; nested pointer.
(define (pancake_host_pending_dial host ticket)
  (let loop ([capacity 4])
    (define hints (malloc _PancakeLocatorHintView capacity 'atomic-interior))
    (define view (make-PancakeLocatorView 0 0 #f 0 #f 0 #f 0 0))
    (define count (malloc _size 'atomic-interior))
    (ptr-set! count _size 0)
    (define rc
      (pancake_host_pending_dial* host ticket hints capacity view count))
    (define required (ptr-ref count _size))
    (if (= rc ERR-BUFFER-TOO-SMALL)
        (loop required)
        (values rc view))))
