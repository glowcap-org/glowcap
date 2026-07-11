#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_driver, the byte-fed
;; host archive (ADR-0072).
;;
;; Nothing here is public. The archive is a companion of libpancake_ocapn: it
;; exports only the `pancake_host_*` family and shares the frame, argument,
;; reference, and last-abort layouts declared in `ffi-shared.rkt`, so this
;; loader opens ONLY libpancake_driver and declares no core symbol. The host
;; surface over it lives in `private/host.rkt` and `private/connection.rkt`.
;;
;; Callback discipline: the behavior callback fires synchronously on the
;; Racket thread executing the enclosing `pancake_host_*` call, so a plain
;; `_fun` callback type is correct — no `#:async-apply`. A trampoline stays
;; alive only while its Racket closure does, so every behavior closure
;; registered with the host is retained in the host's strong `keep` table
;; (`private/host.rkt`) until the host dies. Settlements carry no callback at
;; all: they ride the action queue as SETTLE/FAIL and the drain routes them by
;; vow id (`private/connection.rkt`).
(require ffi/unsafe
         ffi/unsafe/define
         racket/runtime-path
         "ffi-shared.rkt")
(provide (all-defined-out))

(define-runtime-path driver-lib-path "../../../zig-out/lib/libpancake_driver")
(define driver-lib (pancake-ffi-lib "pancake_driver" (path->string driver-lib-path)))

(define-ffi-definer define-driver driver-lib)

;; The C callback type (pancake_driver.h). `_fun` makes a Racket closure
;; C-callable; the closure must stay reachable while the host may invoke it.
(define _PancakeHostBehavior
  (_fun _pointer _pointer _pointer _size _pointer _size _PancakeArgument-pointer -> _int32))

;; ── Lifecycle ─────────────────────────────────────────────────────────────────
(define-driver pancake_host_new
  (_fun _pointer _size _size _uint32 _uint32 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_release (_fun _pointer -> _void))
(define-driver pancake_host_set_self_designator (_fun _pointer _pointer _size -> _int32))
(define-driver pancake_host_conn_open_dialed
  (_fun _pointer _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_conn_open_accepted
  (_fun _pointer _pointer _size _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_conn_release (_fun _pointer -> _void))
(define-driver pancake_host_conn_session_open (_fun _pointer -> _int32))

;; ── The byte pump and action queue ───────────────────────────────────────────
(define-driver pancake_host_conn_feed_bytes
  (_fun _pointer _pointer _size (out : (_ptr o _size)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_conn_take_outbound (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-driver pancake_host_next_action (_fun _pointer _PancakeHostAction-pointer -> _int32))
(define-driver pancake_host_dialed (_fun _pointer _uint64 _pointer -> _int32))
(define-driver pancake_host_dial_failed (_fun _pointer _uint64 _pointer _size -> _int32))
(define-driver pancake_host_provide_gift_id (_fun _pointer _uint64 _pointer _size -> _int32))

;; ── Publish and spawn ────────────────────────────────────────────────────────
;; The `free` parameter is always NULL from this binding (`_pointer`, passed
;; #f): the Racket side owns its trampoline closures through the host's keep
;; table, so there is nothing for the library to free.
(define-driver pancake_host_conn_publish
  (_fun _pointer _pointer _size _PancakeHostBehavior _pointer _pointer
        (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_conn_spawn
  (_fun _pointer _PancakeHostBehavior _pointer _pointer
        (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_publish
  (_fun _pointer _pointer _size _PancakeHostBehavior _pointer _pointer -> _int32))

;; ── Fetch and enliven ────────────────────────────────────────────────────────
;; Each mints a host vow (returned through the out param) whose outcome
;; arrives as that vow's SETTLE/FAIL action.
(define-driver pancake_host_conn_fetch
  (_fun _pointer _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_conn_enliven
  (_fun _pointer _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))

;; ── Send, tell, vows, projections ────────────────────────────────────────────
(define-driver pancake_host_conn_send
  (_fun _pointer _PancakeReference-pointer _pointer _size _pointer _size
        (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-driver pancake_host_conn_tell
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
(define-driver pancake_host_conn_break_far_vows (_fun _pointer _pointer _size -> _int32))
(define-driver pancake_host_conn_set_exporter_location (_fun _pointer _pointer _size -> _int32))
(define-driver pancake_host_conn_last_abort (_fun _pointer _PancakeLastAbort-pointer -> _int32))
(define-driver pancake_host_last_error (_fun _pointer _size -> _size))
