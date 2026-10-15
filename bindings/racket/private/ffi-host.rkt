#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for the `glowcap_host_*` byte-fed
;; host family (ADR-0072), loaded from its own libglowcap_host archive.
;;
;; Nothing here is public. The shared frame, argument, reference, and
;; last-abort layouts stay in `ffi-shared.rkt`. The host surface
;; spans `private/host.rkt`, `private/host/state.rkt`, `private/session.rkt`,
;; `private/action.rkt`, `private/pump.rkt`, and the trampoline's
;; turn-to-session projection.
;;
;; Callback discipline: the behavior callback fires synchronously on the
;; Racket thread executing the enclosing `glowcap_host_*` call, so a plain
;; `_fun` callback type is correct, with no `#:async-apply`. A trampoline stays
;; alive only while its Racket closure does, so every behavior closure
;; registered with the host is retained in the host's strong `keep` table
;; (`private/host/state.rkt`) until the host dies. Settlements carry no callback at
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
         "lib-resolve.rkt"
         (only-in "ffi-ocapn.rkt" glowcap_locator_clone)
         "ffi-host-gen.rkt"
         "ffi-shared.rkt")
(require-archive-fingerprint!
 'host glowcap_host_archive_fingerprint HOST-ARCHIVE-FINGERPRINT)
(provide (except-out (all-from-out "ffi-host-gen.rkt")
                     glowcap_host_pending_dial*)
         (all-from-out "ffi-shared.rkt")
         glowcap_host_pending_dial)

;; Clone the complete pending locator for `ticket`. The C call projects its hint
;; array into caller-owned storage, so this bespoke wrapper probes for the exact
;; required count and performs `glowcap_locator_clone` before that storage can go
;; out of scope. Bespoke rather than generated because one output's capacity
;; controls the other output's nested pointer.
(define (glowcap_host_pending_dial host ticket route-index)
  (define (clone-pending rc view)
    (if (= rc OK)
        (glowcap_locator_clone view)
        (values rc #f)))
  (define view (make-GlowcapLocatorView 0 0 #f 0 #f 0 #f 0 0))
  (define count (malloc _size 'atomic-interior))
  (ptr-set! count _size 0)
  (define probe-rc
    (glowcap_host_pending_dial* host ticket route-index #f 0 view count))
  (cond
    [(= probe-rc ERR-BUFFER-TOO-SMALL)
     (define required (ptr-ref count _size))
     (define hints (malloc _GlowcapLocatorHintView required 'atomic-interior))
     (define copy-view (make-GlowcapLocatorView 0 0 #f 0 #f 0 #f 0 0))
     (define copy-count (malloc _size 'atomic-interior))
     (ptr-set! copy-count _size 0)
     (define copy-rc
       (glowcap_host_pending_dial* host ticket route-index hints required copy-view copy-count))
     (clone-pending copy-rc copy-view)]
    [else
     (clone-pending probe-rc view)]))
