#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_driver, the byte-fed
;; host archive (ADR-0072).
;;
;; Nothing here is public. The archive is a companion of libpancake_ocapn: it
;; exports only the `pancake_host_*` family and shares the frame, argument,
;; reference, and last-abort layouts declared in `ffi-shared.rkt`, so this
;; loader opens ONLY libpancake_driver and declares no core symbol. The host
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
(require ffi/unsafe
         ffi/unsafe/define
         "ffi-shared.rkt"
         "lib-resolve.rkt")
(provide (all-defined-out))

(define driver-lib (open-pancake-archive "pancake_driver"))

(define-ffi-definer define-driver driver-lib)

;; The C callback type (pancake_driver.h). `_fun` makes a Racket closure
;; C-callable; the closure must stay reachable while the host may invoke it.
(define _PancakeHostBehavior
  (_fun _pointer _pointer _pointer _size _pointer _size _PancakeArgument-pointer -> _int32))

;; PancakeDialPlan (pancake_driver.h): the resolved dial pancake_host_plan_dial
;; hands back. `shape` selects the live fields (HOST-PORT fills host/port, IROH
;; fills addresses/reach); host/addresses borrow the caller's input buffers.
(define-cstruct _PancakeDialPlan
  ([shape _uint32] [host _pointer] [host-len _size] [port _uint16]
   [addresses _pointer] [addresses-len _size]
   [reach-kind _uint32] [reach-value _uint32]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeDialPlan _PancakeDialPlan 56
             '(uint32 pointer uint64 uint16 pointer uint64 uint32 uint32))

;; ── Lifecycle ─────────────────────────────────────────────────────────────────
(define-driver pancake_host_new
  (_fun _pointer _size _size _uint32 _uint32 _uint32 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_release (_fun _pointer -> _void))
(define-driver pancake_host_designator_from_seed
  (_fun _pointer _size _pointer _size -> _int32))
(define-driver pancake_host_set_self_designator (_fun _pointer _pointer _size -> _int32))
(define-driver pancake_host_session_open_dialed_locator
  (_fun _pointer _pointer _size _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
;; Resolve a dial to a _PancakeDialPlan (grammar + hint + iroh posture); free function.
(define-driver pancake_host_plan_dial
  (_fun _pointer _size _pointer _size _pointer _size _uint32 _uint32 _PancakeDialPlan-pointer -> _int32))
(define-driver pancake_host_session_open_accepted
  (_fun _pointer _pointer _size _pointer _size _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_session_release (_fun _pointer -> _void))
(define-driver pancake_host_session_session_open (_fun _pointer -> _int32))

;; ── The byte pump and action queue ───────────────────────────────────────────
(define-driver pancake_host_session_feed_bytes
  (_fun _pointer _pointer _size (out : (_ptr o _size)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_session_take_outbound (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-driver pancake_host_next_action (_fun _pointer _PancakeHostAction-pointer -> _int32))
(define-driver pancake_host_dialed (_fun _pointer _uint64 _pointer -> _int32))
(define-driver pancake_host_dial_failed (_fun _pointer _uint64 _pointer _size -> _int32))
(define-driver pancake_host_provide_gift_id (_fun _pointer _uint64 _pointer _size -> _int32))

;; ── Publish and spawn ────────────────────────────────────────────────────────
;; The `free` parameter is always NULL from this binding (`_pointer`, passed
;; #f): the Racket side owns its trampoline closures through the host's keep
;; table, so there is nothing for the library to free.
(define-driver pancake_host_session_publish
  (_fun _pointer _pointer _size _PancakeHostBehavior _pointer _pointer
        (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_session_spawn
  (_fun _pointer _PancakeHostBehavior _pointer _pointer
        (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_publish
  (_fun _pointer _pointer _size _PancakeHostBehavior _pointer _pointer -> _int32))

;; ── Fetch and enliven ────────────────────────────────────────────────────────
;; Each mints a host vow (returned through the out param) whose outcome
;; arrives as that vow's SETTLE/FAIL action.
(define-driver pancake_host_session_fetch
  (_fun _pointer _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_session_enliven
  (_fun _pointer _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))

;; ── Send, tell, vows, projections ────────────────────────────────────────────
(define-driver pancake_host_session_send
  (_fun _pointer _PancakeReference-pointer _pointer _size _pointer _size
        (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_session_tell
  (_fun _pointer _PancakeReference-pointer _pointer _size _pointer _size -> _int32))
(define-driver pancake_host_vow_send
  (_fun _pointer _uint64 _pointer _size _pointer _size
        (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_vow_index
  (_fun _pointer _uint64 _uint64 (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_vow_untag
  (_fun _pointer _uint64 _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))

;; ── Turn verbs (legal only inside a behavior callback) ──────────────────────
(define-driver pancake_host_turn_forward
  (_fun _pointer _PancakeReference-pointer _pointer _size _pointer _size
        _PancakeArgument-pointer -> _int32))
(define-driver pancake_host_turn_spawn
  (_fun _pointer _PancakeHostBehavior _pointer _pointer
        (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_turn_break (_fun _pointer _pointer _size -> _int32))

;; ── GC, teardown, diagnostics ────────────────────────────────────────────────
(define-driver pancake_host_gc_release (_fun _pointer _uint64 _uint64 -> _int32))
(define-driver pancake_host_session_break_far_vows (_fun _pointer _pointer _size -> _int32))
(define-driver pancake_host_session_set_exporter_location (_fun _pointer _pointer _size -> _int32))
(define-driver pancake_host_session_last_abort (_fun _pointer _PancakeLastAbort-pointer -> _int32))
(define-driver pancake_host_last_error (_fun _pointer _size -> _size))
