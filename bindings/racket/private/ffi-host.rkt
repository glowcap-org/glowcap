#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_host, the byte-fed
;; host archive (ADR-0072).
;;
;; Nothing here is public. The archive is a companion of libpancake_ocapn: it
;; exports only the `pancake_host_*` family and shares the frame, argument,
;; reference, and last-abort layouts declared in `ffi-shared.rkt`, so this
;; loader opens ONLY libpancake_host and declares no core symbol. The host
;; surface over it spans `private/host.rkt`, `private/session.rkt`,
;; `private/action.rkt`, and `private/pump.rkt`.
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
         "ffi-host-gen.rkt"
         "ffi-shared.rkt")
(provide (except-out (all-from-out "ffi-host-gen.rkt")
                     pancake_host_pending_dial*)
         (all-from-out "ffi-shared.rkt")
         pancake_host_set_advertised_locator
         pancake_host_ensure_advertised_locator
         pancake_host_remove_advertised_locator
         pancake_host_pending_dial)

;; The generated table covers the archive inventory; this handwritten loader
;; binds the locator-state exports that are outside that inventory.
(define pancake_host_set_advertised_locator
  (get-ffi-obj "pancake_host_set_advertised_locator" driver-lib
               (_fun _pointer _pointer _size -> _int32)))
(define pancake_host_ensure_advertised_locator
  (get-ffi-obj "pancake_host_ensure_advertised_locator" driver-lib
               (_fun _pointer _pointer _size -> _int32)))
(define pancake_host_remove_advertised_locator
  (get-ffi-obj "pancake_host_remove_advertised_locator" driver-lib
               (_fun _pointer _pointer _size -> _int32)))

;; Borrow the pending dial for `ticket` (no URI re-parse) and materialize the
;; three views as fresh byte copies before the borrow window closes. Returns
;; `(values rc transport designator hint)`. Bespoke rather than generated:
;; the out-param is a struct view whose fields the wrapper reads, not a cell
;; the mechanical tier can synthesize.
(define (pancake_host_pending_dial host ticket)
  (define view (make-PancakePendingDial #f 0 #f 0 #f 0))
  (define rc (pancake_host_pending_dial* host ticket view))
  (define (view-bytes ptr len)
    (if (or (not ptr) (zero? len)) #"" (bytes<-c ptr len)))
  (values rc
          (view-bytes (PancakePendingDial-transport view) (PancakePendingDial-transport-len view))
          (view-bytes (PancakePendingDial-designator view) (PancakePendingDial-designator-len view))
          (view-bytes (PancakePendingDial-hint view) (PancakePendingDial-hint-len view))))
