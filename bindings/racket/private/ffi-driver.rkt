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
;;
;; Every C out-param is a fresh caller-owned cell allocated inside the public
;; wrapper (`wrap-out1` / `call/outs` in `ffi-shared.rkt`). Star-suffixed raw
;; stubs stay unprovided. Callers see `(values rc …)` only.
(require ffi/unsafe
         ffi/unsafe/define
         "ffi-shared.rkt"
         "layouts-gen.rkt"
         "lib-resolve.rkt")
(provide (except-out (all-defined-out)
                     pancake_host_new*
                     pancake_host_session_open_dialed_locator*
                     pancake_host_pending_dial*
                     pancake_host_session_open_accepted*
                     pancake_host_session_feed_bytes*
                     pancake_host_session_publish*
                     pancake_host_session_spawn*
                     pancake_host_session_fetch*
                     pancake_host_session_enliven*
                     pancake_host_session_send*
                     pancake_host_vow_send*
                     pancake_host_vow_index*
                     pancake_host_vow_untag*
                     pancake_host_vow_get*
                     pancake_host_turn_spawn*))

(define driver-lib (open-pancake-archive "pancake_driver"))

(define-ffi-definer define-driver driver-lib)

;; The C callback type (pancake_driver.h). `_fun` makes a Racket closure
;; C-callable; the closure must stay reachable while the host may invoke it.
(define _PancakeHostBehavior
  (_fun _pointer _pointer _pointer _size _pointer _size _PancakeArgument-pointer -> _int32))

;; Sync arm for pancake_host_pump_drain (ADR-0072 fifth amendment). Must not
;; await — park decoded work and run I/O after the C loop returns.
(define _PancakeHostPumpArmFn
  (_fun _pointer _pointer _PancakeHostAction-pointer _pointer -> _int32))

;; PancakeHostPumpHooks (pancake_driver.h) — five arm slots + caller ctx.
;; Fields are `_fpointer` so `function-ptr` callbacks install cleanly.
(define-cstruct _PancakeHostPumpHooks
  ([ctx _pointer]
   [flush _fpointer] [close _fpointer] [need-gift-id _fpointer]
   [complete _fpointer] [dial _fpointer]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeHostPumpHooks _PancakeHostPumpHooks PANCAKE-HOST-PUMP-HOOKS-SIZE
             '(pointer fpointer fpointer fpointer fpointer fpointer))

;; PancakeDialPlan (pancake_driver.h): the resolved dial pancake_host_plan_dial
;; hands back. `shape` selects the live fields (HOST-PORT fills host/port,
;; PEER-ID fills addresses/reach); host/addresses borrow the caller's input buffers.
(define-cstruct _PancakeDialPlan
  ([shape _uint32] [host _pointer] [host-len _size] [port _uint16]
   [addresses _pointer] [addresses-len _size]
   [reach-kind _uint32] [reach-value _uint32]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeDialPlan _PancakeDialPlan PANCAKE-DIAL-PLAN-SIZE
             '(uint32 pointer uint64 uint16 pointer uint64 uint32 uint32))

;; ── Lifecycle ─────────────────────────────────────────────────────────────────
(define-driver pancake_host_new*
  (_fun _pointer _size _size _uint32 _uint32 _uint32 _pointer -> _int32)
  #:c-id pancake_host_new)
(define pancake_host_new (wrap-out1 pancake_host_new* _pointer #f))
(define-driver pancake_host_release (_fun _pointer -> _void))
(define-driver pancake_host_designator_from_seed
  (_fun _pointer _size _pointer _size -> _int32))
(define-driver pancake_host_set_self_designator (_fun _pointer _pointer _size -> _int32))
(define-driver pancake_host_set_session_limits (_fun _pointer _size _size -> _int32))
(define-driver pancake_host_session_open_dialed_locator*
  (_fun _pointer _pointer _size _pointer _size _pointer -> _int32)
  #:c-id pancake_host_session_open_dialed_locator)
(define pancake_host_session_open_dialed_locator
  (wrap-out1 pancake_host_session_open_dialed_locator* _pointer #f))
;; Resolve a dial to a _PancakeDialPlan (grammar + hint + iroh posture); free function.
(define-driver pancake_host_plan_dial
  (_fun _pointer _size _pointer _size _pointer _size _uint32 _uint32 _PancakeDialPlan-pointer -> _int32))
;; PancakeAcceptPlan: signing designator + hint from pancake_host_plan_accept.
(define-cstruct _PancakeAcceptPlan
  ([designator _pointer]
   [designator-len _size]
   [direct-addresses-hint _pointer]
   [direct-addresses-hint-len _size]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeAcceptPlan _PancakeAcceptPlan PANCAKE-ACCEPT-PLAN-SIZE
             '(pointer uint64 pointer uint64))
(define-driver pancake_host_plan_accept
  (_fun _pointer _size _pointer _size _pointer _size _PancakeAcceptPlan-pointer -> _int32))
;; Borrowed pending dial view (transport/designator/hint).
(define-cstruct _PancakePendingDial
  ([transport _pointer]
   [transport-len _size]
   [designator _pointer]
   [designator-len _size]
   [hint _pointer]
   [hint-len _size]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakePendingDial _PancakePendingDial PANCAKE-PENDING-DIAL-SIZE
             '(pointer uint64 pointer uint64 pointer uint64))
;; Borrow the pending dial for `ticket` (no URI re-parse).
;; Returns `(values rc transport designator hint)` as fresh byte copies.
(define-driver pancake_host_pending_dial*
  (_fun _pointer _uint64 _PancakePendingDial-pointer -> _int32)
  #:c-id pancake_host_pending_dial)
(define (pancake_host_pending_dial host ticket)
  (define view (make-PancakePendingDial #f 0 #f 0 #f 0))
  (define rc (pancake_host_pending_dial* host ticket view))
  (define (view-bytes ptr len)
    (if (or (not ptr) (zero? len)) #"" (bytes<-c ptr len)))
  (values rc
          (view-bytes (PancakePendingDial-transport view) (PancakePendingDial-transport-len view))
          (view-bytes (PancakePendingDial-designator view) (PancakePendingDial-designator-len view))
          (view-bytes (PancakePendingDial-hint view) (PancakePendingDial-hint-len view))))
(define-driver pancake_host_session_open_accepted*
  (_fun _pointer _pointer _size _pointer _size _pointer _size _pointer -> _int32)
  #:c-id pancake_host_session_open_accepted)
(define pancake_host_session_open_accepted
  (wrap-out1 pancake_host_session_open_accepted* _pointer #f))
(define-driver pancake_host_session_release (_fun _pointer -> _void))
(define-driver pancake_host_session_session_open (_fun _pointer -> _int32))

;; ── The byte pump and action queue ───────────────────────────────────────────
(define-driver pancake_host_session_feed_bytes*
  (_fun _pointer _pointer _size _pointer -> _int32)
  #:c-id pancake_host_session_feed_bytes)
(define pancake_host_session_feed_bytes
  (wrap-out1 pancake_host_session_feed_bytes* _size 0))
(define-driver pancake_host_session_take_outbound (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-driver pancake_host_next_action (_fun _pointer _PancakeHostAction-pointer -> _int32))
;; Opt-in one-loop drain (ADR-0072 fifth). Bindings park in sync arms; the
;; pull-queue (`pancake_host_next_action`) stays normative inside C.
(define-driver pancake_host_pump_drain
  (_fun _pointer _PancakeHostPumpHooks-pointer _pointer -> _int32))
(define-driver pancake_host_dialed (_fun _pointer _uint64 _pointer -> _int32))
(define-driver pancake_host_dial_failed (_fun _pointer _uint64 _pointer _size -> _int32))
(define-driver pancake_host_provide_gift_id (_fun _pointer _uint64 _pointer _size -> _int32))

;; ── Publish and spawn ────────────────────────────────────────────────────────
;; The `free` parameter is always NULL from this binding (`_pointer`, passed
;; #f): the Racket side owns its trampoline closures through the host's keep
;; table, so there is nothing for the library to free.
(define-driver pancake_host_session_publish*
  (_fun _pointer _pointer _size _PancakeHostBehavior _pointer _pointer _pointer -> _int32)
  #:c-id pancake_host_session_publish)
(define pancake_host_session_publish
  (wrap-out1 pancake_host_session_publish* _uint64 0))
(define-driver pancake_host_session_spawn*
  (_fun _pointer _PancakeHostBehavior _pointer _pointer _pointer -> _int32)
  #:c-id pancake_host_session_spawn)
(define pancake_host_session_spawn
  (wrap-out1 pancake_host_session_spawn* _uint64 0))
(define-driver pancake_host_publish
  (_fun _pointer _pointer _size _PancakeHostBehavior _pointer _pointer -> _int32))

;; ── Fetch and enliven ────────────────────────────────────────────────────────
;; Each mints a host vow (returned through the out param) whose outcome
;; arrives as that vow's SETTLE/FAIL action.
(define-driver pancake_host_session_fetch*
  (_fun _pointer _pointer _size _pointer -> _int32)
  #:c-id pancake_host_session_fetch)
(define pancake_host_session_fetch
  (wrap-out1 pancake_host_session_fetch* _uint64 0))
(define-driver pancake_host_session_enliven*
  (_fun _pointer _pointer _size _pointer -> _int32)
  #:c-id pancake_host_session_enliven)
(define pancake_host_session_enliven
  (wrap-out1 pancake_host_session_enliven* _uint64 0))

;; ── Send, tell, vows, projections ────────────────────────────────────────────
(define-driver pancake_host_session_send*
  (_fun _pointer _PancakeReference-pointer _pointer _size _pointer _size _pointer -> _int32)
  #:c-id pancake_host_session_send)
(define pancake_host_session_send
  (wrap-out1 pancake_host_session_send* _uint64 0))
(define-driver pancake_host_session_tell
  (_fun _pointer _PancakeReference-pointer _pointer _size _pointer _size -> _int32))
(define-driver pancake_host_vow_send*
  (_fun _pointer _uint64 _pointer _size _pointer _size _pointer -> _int32)
  #:c-id pancake_host_vow_send)
(define pancake_host_vow_send
  (wrap-out1 pancake_host_vow_send* _uint64 0))
(define-driver pancake_host_vow_index*
  (_fun _pointer _uint64 _uint64 _pointer -> _int32)
  #:c-id pancake_host_vow_index)
(define pancake_host_vow_index
  (wrap-out1 pancake_host_vow_index* _uint64 0))
(define-driver pancake_host_vow_untag*
  (_fun _pointer _uint64 _pointer _size _pointer -> _int32)
  #:c-id pancake_host_vow_untag)
(define pancake_host_vow_untag
  (wrap-out1 pancake_host_vow_untag* _uint64 0))
(define-driver pancake_host_vow_get*
  (_fun _pointer _uint64 _pointer _size _pointer -> _int32)
  #:c-id pancake_host_vow_get)
(define pancake_host_vow_get
  (wrap-out1 pancake_host_vow_get* _uint64 0))

;; ── Turn verbs (legal only inside a behavior callback) ──────────────────────
(define-driver pancake_host_turn_forward
  (_fun _pointer _PancakeReference-pointer _pointer _size _pointer _size
        _PancakeArgument-pointer -> _int32))
(define-driver pancake_host_turn_spawn*
  (_fun _pointer _PancakeHostBehavior _pointer _pointer _pointer -> _int32)
  #:c-id pancake_host_turn_spawn)
(define pancake_host_turn_spawn
  (wrap-out1 pancake_host_turn_spawn* _uint64 0))
(define-driver pancake_host_turn_break (_fun _pointer _pointer _size -> _int32))

;; ── GC, teardown, diagnostics ────────────────────────────────────────────────
(define-driver pancake_host_gc_release (_fun _pointer _uint64 _uint64 -> _int32))
(define-driver pancake_host_session_break_far_vows (_fun _pointer _pointer _size -> _int32))
(define-driver pancake_host_session_set_exporter_location (_fun _pointer _pointer _size -> _int32))
(define-driver pancake_host_session_last_abort (_fun _pointer _PancakeLastAbort-pointer -> _int32))
(define-driver pancake_host_last_error (_fun _pointer _size -> _size))
