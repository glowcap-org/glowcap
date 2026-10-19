#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for the `glowcap_driver_*` loop
;; family (ADR-0024).
;;
;; Nothing here is public. libglowcap_driver exports only this family and
;; adopts a Host from the symbol-disjoint libglowcap_host archive. The result
;; is a stepping `driver.HostRuntime` behind one readiness descriptor and one
;; event queue.
;;
;; The loop tier over these verbs lives in `private/loop/`: park on the
;; readiness fd, step zero-timeout, drain `glowcap_driver_next_event` until
;; WOULD-BLOCK. Behavior callbacks fire inside `glowcap_driver_step` exactly
;; as they fire inside a byte-fed feed, on the calling Racket thread.
;;
;; The bound functions and their out-cell wrappers are generated from the
;; archive's annotated symbol inventory (`ffi-driver-gen.rkt`, `zig build
;; gen-binding-racket-ffi`); the event and multiplexed-transport cstructs live in
;; `ffi-shared.rkt`, the binding's types leaf. Every C out-param is a fresh
;; caller-owned cell inside a generated wrapper; star-suffixed raw stubs stay
;; unprovided. Callers see `(values rc …)` only.
(require "constants.rkt"
         "lib-resolve.rkt"
         "ffi-driver-gen.rkt"
         "ffi-shared.rkt")
(require-archive-fingerprint!
 'driver glowcap_driver_archive_fingerprint DRIVER-ARCHIVE-FINGERPRINT)
(provide (all-from-out "ffi-driver-gen.rkt")
         (all-from-out "ffi-shared.rkt"))
