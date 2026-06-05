#lang racket/base
;; Racket (ffi/unsafe) dogfood of the Zig libpancake C ABI.
;;
;; The Racket sibling of `bindings/rust`'s `rust_consumes_zig_peer_c_abi`:
;; open the shared library, create a peer, feed a borrowed `op:abort` frame,
;; and assert the surfaced event is an Abort. This exercises the slice of the
;; binding that consumes the Zig C ABI as it exists today; the richer
;; Goblins/CapTP surface under `racket/` is pending the C ABI's growth
;; (see README.md).

(require ffi/unsafe
         ffi/unsafe/define
         racket/runtime-path)

(define PANCAKE_OK 0)
(define PANCAKE_FRAME_SHAPE_BYTE 0)
(define PANCAKE_EVENT_ABORT 7)

(define-runtime-path lib-path "../../zig-out/lib/libpancake.so")
(define lib (ffi-lib (path->string lib-path)))

(define-cstruct _PancakeFrame ([bytes _pointer] [len _size] [shape _uint32]))
(define-cstruct _PancakeManagedFrame
  ([bytes _pointer] [len _size] [shape _uint32] [release _pointer] [private-data _pointer]))
(define-cstruct _PancakeEvent ([kind _uint32] [frame _PancakeManagedFrame]))

(define pancake-peer-new
  (get-ffi-obj "pancake_peer_new" lib
               (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out))))
(define pancake-peer-feed-borrowed
  (get-ffi-obj "pancake_peer_feed_borrowed" lib
               (_fun _pointer _PancakeFrame-pointer -> _int32)))
(define pancake-peer-poll-event
  (get-ffi-obj "pancake_peer_poll_event" lib
               (_fun _pointer _PancakeEvent-pointer -> _int32)))
(define pancake-event-release
  (get-ffi-obj "pancake_event_release" lib (_fun _PancakeEvent-pointer -> _void)))
(define pancake-peer-release
  (get-ffi-obj "pancake_peer_release" lib (_fun _pointer -> _void)))

(define (fail msg)
  (eprintf "racket zig-smoke FAILED: ~a\n" msg)
  (exit 1))

(define-values (rc peer) (pancake-peer-new))
(unless (and (= rc PANCAKE_OK) peer) (fail "peer_new"))

(define payload #"<8'op:abort3\"bye>")
(define n (bytes-length payload))
(define buf (malloc n 'raw))
(memcpy buf payload n)
(define frame (make-PancakeFrame buf n PANCAKE_FRAME_SHAPE_BYTE))
(unless (= PANCAKE_OK (pancake-peer-feed-borrowed peer frame))
  (fail "feed_borrowed(op:abort)"))

(define ev (make-PancakeEvent 0 (make-PancakeManagedFrame #f 0 0 #f #f)))
(unless (= PANCAKE_OK (pancake-peer-poll-event peer ev)) (fail "poll_event"))
(unless (= PANCAKE_EVENT_ABORT (PancakeEvent-kind ev))
  (fail (format "event kind ~a != ABORT" (PancakeEvent-kind ev))))

(pancake-event-release ev)
(pancake-peer-release peer)
(free buf)
(printf "racket zig-smoke OK: consumed Zig libpancake C ABI (op:abort)\n")
