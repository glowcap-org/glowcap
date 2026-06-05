#lang racket/base

;; pancake-ffi.rkt — racket/foreign bindings for libpancake's typed C ABI.
;;
;; Mirrors the surface in `crates/ffi/pancake-ffi-runtime/include/pancake.h`. The
;; bindings are partitioned roughly the way the C header is:
;;
;;   1. Library loading + the FFI definer.
;;   2. Error-code + session-state + step-kind constants.
;;   3. Opaque handles (PancakePeer, PancakeSturdyrefDedup, PancakeFrame).
;;   4. Lifecycle (new / free / shutdown).
;;   5. Per-peer step + queues (feed_inbound / step / take_outbound /
;;      poll_event_kind / session_state / has_outbound / has_event).
;;   6. Typed value types (PancakeReference, PancakeArgument,
;;      PancakeResolution) + Racket-side builders for each variant.
;;   7. Typed send + receive (send_deliver / send_resolve /
;;      send_start_session / poll_event_deliver / poll_event_resolve).
;;   8. Cross-peer entry points.
;;   9. Last-error retrieval.
;;
;; Layout assumptions: 64-bit pointers + LP64 alignment. Tested
;; architectures on the pancake side are x86_64-linux,
;; aarch64-linux, x86_64-darwin, aarch64-darwin. Windows / 32-bit
;; would need the cstruct paddings revisited.
;;
;; Lifetime contract — every `pancake_*_new`-returned handle must be
;; released via the matching `pancake_*_free`. Every Box::into_raw'd
;; receive-side buffer (args arrays, abort messages, partner
;; locators, resolutions) must be released via the matching
;; pancake_typed_*_free helper. This module wraps the raw FFI in
;; Racket-side disposers so users get safe defaults; the raw `_unsafe`
;; variants are exposed for advanced callers.

(require ffi/unsafe
         ffi/unsafe/define
         racket/match)

(provide
  ;; Library load
  current-pancake-lib
  
  ;; Constants
  PANCAKE_OK
  PANCAKE_ERR_NULL_POINTER PANCAKE_ERR_INVALID_HANDLE PANCAKE_ERR_PEER_CLOSED
  PANCAKE_ERR_SESSION PANCAKE_ERR_CODEC PANCAKE_ERR_INTERNAL
  PANCAKE_ERR_INVALID_UTF8 PANCAKE_ERR_INVALID_CODEC
  PANCAKE_ERR_HANDSHAKE_INCOMPLETE PANCAKE_ERR_PANIC
  PANCAKE_CODEC_CAPNP PANCAKE_CODEC_SYRUP
  PANCAKE_CAPTP_VERSION_PRESPEC PANCAKE_CAPTP_VERSION_V1_0
  PANCAKE_STEP_MORE_WORK PANCAKE_STEP_IDLE PANCAKE_STEP_CLOSED
  PANCAKE_SESSION_NEGOTIATING PANCAKE_SESSION_OPEN PANCAKE_SESSION_CLOSED
  PANCAKE_REF_NEAR PANCAKE_REF_FAR PANCAKE_REF_PROMISE
  PANCAKE_REF_STURDY PANCAKE_REF_BROKEN
  PANCAKE_ARG_SYMBOL PANCAKE_ARG_BYTES PANCAKE_ARG_REFERENCE
  PANCAKE_ARG_INTEGER PANCAKE_ARG_BOOL PANCAKE_ARG_STRING PANCAKE_ARG_VOID
  PANCAKE_ARG_LIST
  PANCAKE_RES_FULFILL PANCAKE_RES_BREAK
  PANCAKE_ABORT_REASON_GRACEFUL_SHUTDOWN
  PANCAKE_ABORT_REASON_VERSION_MISMATCH
  PANCAKE_ABORT_REASON_PROTOCOL_ERROR
  PANCAKE_EVENT_KIND_PEER_READY
  PANCAKE_EVENT_KIND_PEER_CLOSED
  PANCAKE_EVENT_KIND_SESSION_ESTABLISHED
  PANCAKE_EVENT_KIND_SESSION_ABORTED
  PANCAKE_EVENT_KIND_DELIVER_RECEIVED
  PANCAKE_EVENT_KIND_RESOLVE_RECEIVED
  PANCAKE_EVENT_KIND_ABORT_RECEIVED
  
  ;; Library metadata
  pancake-version
  
  ;; Lifecycle
  pancake-peer-new pancake-peer-new-advanced
  pancake-peer-get-my-peer-id pancake-peer-get-partner-peer-id
  pancake-peer-free pancake-peer-shutdown
  pancake-peer-register-bootstrap-cap
  pancake-peer-register-export
  
  ;; Step / queues
  pancake-peer-step
  pancake-peer-feed-inbound       ; feed inbound bytes; runtime borrows them for the call (zero-copy)
  pancake-peer-feed-inbound-ptr   ; feed inbound from a raw (ptr,len) borrow; no Racket copy
  pancake-peer-take-outbound      ; returns bytes or #f
  pancake-managed-frame-release
  PancakeManagedFrame-bytes PancakeManagedFrame-len
  pancake-peer-peek-event-kind
  pancake-peer-consume-event
  pancake-peer-session-state
  pancake-peer-has-outbound
  pancake-peer-has-event
  
  ;; Typed value type builders + accessors
  (struct-out pcakeref)
  (struct-out pcakearg)
  (struct-out pcakeres)
  ref-near ref-far ref-sturdy
  arg-symbol arg-bytes arg-reference arg-integer arg-bool arg-string arg-void
  arg-list
  res-fulfill res-break
  
  ;; Typed send
  pancake-peer-send-deliver
  pancake-peer-send-resolve
  pancake-peer-send-start-session
  pancake-peer-enliven-sturdyref
  pancake-peer-send-abort
  
  ;; Ed25519 keypair lifecycle
  pancake-keypair-new
  pancake-keypair-from-seed
  pancake-keypair-free
  pancake-keypair-pubkey
  
  ;; OCapN URI parser (C3)
  (struct-out ocapn-uri)
  pancake-ocapn-uri-parse
  
  ;; Syrup frame probe (F1)
  PANCAKE_FRAME_COMPLETE
  PANCAKE_FRAME_INCOMPLETE
  PANCAKE_FRAME_MALFORMED
  pancake-syrup-frame-probe
  
  ;; TCP endpoint (Matrix #3)
  PANCAKE_ENDPOINT_TCP_ERR_IO
  PANCAKE_ENDPOINT_TCP_ERR_MALFORMED
  PANCAKE_ENDPOINT_TCP_ERR_CLOSED
  PANCAKE_ENDPOINT_TCP_ERR_WOULD_BLOCK
  pancake-endpoint-tcp-connect
  pancake-endpoint-tcp-listen
  pancake-endpoint-tcp-accept
  pancake-endpoint-tcp-accept-timed
  pancake-endpoint-tcp-read-frame
  pancake-endpoint-tcp-write-frame
  pancake-endpoint-tcp-write-frame-ptr  ; zero-copy: write a raw (ptr,len)
  pancake-endpoint-tcp-close
  pancake-endpoint-tcp-listener-close
  pancake-endpoint-tcp-set-read-timeout-ms

  ;; TCP+TLS endpoint (stack 3) — same libpancake_ffi_net_tcp cdylib,
  ;; rustls over the sync TCP core.
  pancake-endpoint-tcp-tls-connect
  pancake-endpoint-tcp-tls-listen
  pancake-endpoint-tcp-tls-accept
  pancake-endpoint-tcp-tls-accept-timed
  pancake-endpoint-tcp-tls-read-frame
  pancake-endpoint-tcp-tls-write-frame
  pancake-endpoint-tcp-tls-write-frame-ptr  ; zero-copy
  pancake-endpoint-tcp-tls-close
  pancake-endpoint-tcp-tls-listener-close
  pancake-endpoint-tcp-tls-set-read-timeout-ms

  ;; iroh endpoint (stacks 4 + 5) — libpancake_ffi_net_iroh, QUIC.
  pancake-net-iroh-last-error
  pancake-endpoint-iroh-new
  pancake-endpoint-iroh-endpoint-id
  pancake-endpoint-iroh-bound-addr
  pancake-endpoint-iroh-connect
  pancake-endpoint-iroh-listen
  pancake-endpoint-iroh-accept
  pancake-endpoint-iroh-accept-timed
  pancake-endpoint-iroh-read-frame
  pancake-endpoint-iroh-write-frame
  pancake-endpoint-iroh-write-frame-ptr  ; zero-copy
  pancake-endpoint-iroh-conn-close
  pancake-endpoint-iroh-listener-close
  pancake-endpoint-iroh-close
  pancake-endpoint-iroh-set-read-timeout-ms

  ;; Netlayer-seam vtable + the per-transport bundles.
  (struct-out transport-ops)
  pancake-tcp-transport-ops
  pancake-tcp-tls-transport-ops
  pancake-iroh-transport-ops
  
  ;; Typed receive (returns Racket-side projections; cleanup is automatic)
  pancake-peer-poll-event-deliver
  pancake-peer-poll-event-resolve
  pancake-peer-poll-event-abort
  pancake-peer-poll-event-session-established
  
  ;; Cross-peer
  pancake-sturdyref-dedup-new
  pancake-sturdyref-dedup-free
  pancake-cross-peer-drain-relayed-resolutions
  pancake-cross-peer-absorb-pending-sturdyref-enlivens
  pancake-cross-peer-cache-settled-sturdyref-enlivens
  
  ;; Last error
  pancake-last-error
  pancake-clear-last-error)

;; ─── Library load ───────────────────────────────────────────────────

;; Per ADR-0050/0051 the FFI is a family of cdylibs. PANCAKE_LIB points
;; at the protocol core (libpancake_ffi_runtime); PANCAKE_NET_TCP_LIB at
;; the cleartext TCP netlayer (libpancake_ffi_net_tcp). The two are
;; bridged on the Racket side via the PancakeFrame byte handoff.
(define current-pancake-lib
  (make-parameter
    (or (getenv "PANCAKE_LIB")
        (error 'pancake-ffi
               "PANCAKE_LIB environment variable not set; build the protocol core via `cargo build -p pancake-ffi-runtime --release` and `export PANCAKE_LIB=/path/to/libpancake_ffi_runtime.{so,dylib,dll}`"))))

(define libpancake (ffi-lib (current-pancake-lib)))

(define-ffi-definer define-pancake libpancake)

(define current-pancake-net-tcp-lib
  (make-parameter
    (or (getenv "PANCAKE_NET_TCP_LIB")
        (error 'pancake-ffi
               "PANCAKE_NET_TCP_LIB environment variable not set; build the TCP netlayer via `cargo build -p pancake-ffi-net-tcp --release` and `export PANCAKE_NET_TCP_LIB=/path/to/libpancake_ffi_net_tcp.{so,dylib,dll}`"))))

(define libpancake-net-tcp (ffi-lib (current-pancake-net-tcp-lib)))

(define-ffi-definer define-pancake-net-tcp libpancake-net-tcp)

;; The panic seam (pancake-ffi-abi) is statically linked into EACH
;; cdylib, so the per-thread last-error slot is per-library: a failed
;; net-tcp call stashes its diagnostic in the net-tcp lib's slot, read
;; via this binding (NOT the runtime lib's `pancake-last-error`).
(define-pancake-net-tcp pancake-net-tcp-last-error
  (_fun -> _string)
  #:c-id pancake_last_error)

;; PANCAKE_NET_IROH_LIB = the iroh netlayer cdylib (libpancake_ffi_net_iroh).
;; Carries the QUIC-over-iroh transport surface used by the iroh
;; stacks (4 + 5). Loaded eagerly like the other two so the stack's
;; pixi.toml builds + exports all three; the tcp-only stacks load it
;; but never call into it (cheap dlopen, no cost).
(define current-pancake-net-iroh-lib
  (make-parameter
    (or (getenv "PANCAKE_NET_IROH_LIB")
        (error 'pancake-ffi
               "PANCAKE_NET_IROH_LIB environment variable not set; build the iroh netlayer via `cargo build -p pancake-ffi-net-iroh --release` and `export PANCAKE_NET_IROH_LIB=/path/to/libpancake_ffi_net_iroh.{so,dylib,dll}`"))))

(define libpancake-net-iroh (ffi-lib (current-pancake-net-iroh-lib)))

(define-ffi-definer define-pancake-net-iroh libpancake-net-iroh)

;; iroh lib's own per-library last-error slot (see the net-tcp note).
(define-pancake-net-iroh pancake-net-iroh-last-error
  (_fun -> _string)
  #:c-id pancake_last_error)

;; ─── Constants (mirror crates/ffi/pancake-ffi-runtime/include/pancake.h) ─────────

(define PANCAKE_OK 0)
(define PANCAKE_ERR_NULL_POINTER -1)
(define PANCAKE_ERR_INVALID_HANDLE -2)
(define PANCAKE_ERR_PEER_CLOSED -3)
(define PANCAKE_ERR_SESSION -4)
(define PANCAKE_ERR_CODEC -5)
(define PANCAKE_ERR_INTERNAL -6)
(define PANCAKE_ERR_INVALID_UTF8 -7)
(define PANCAKE_ERR_INVALID_CODEC -8)
;; pancake_peer_get_partner_peer_id called before SessionEstablished.
;; Bindings special-case this to surface "handshake still in progress"
;; rather than a generic session-state error.
(define PANCAKE_ERR_HANDSHAKE_INCOMPLETE -9)
(define PANCAKE_ERR_PANIC -100)

(define PANCAKE_CODEC_CAPNP 0)
(define PANCAKE_CODEC_SYRUP 1)

(define PANCAKE_CAPTP_VERSION_PRESPEC 0)
(define PANCAKE_CAPTP_VERSION_V1_0 1)

(define PANCAKE_STEP_MORE_WORK 0)
(define PANCAKE_STEP_IDLE 1)
(define PANCAKE_STEP_CLOSED 2)

(define PANCAKE_SESSION_NEGOTIATING 0)
(define PANCAKE_SESSION_OPEN 1)
(define PANCAKE_SESSION_CLOSED 2)

(define PANCAKE_REF_NEAR 0)
(define PANCAKE_REF_FAR 1)
(define PANCAKE_REF_PROMISE 2)
(define PANCAKE_REF_STURDY 3)
(define PANCAKE_REF_BROKEN 4)

(define PANCAKE_ARG_SYMBOL 0)
(define PANCAKE_ARG_BYTES 1)
(define PANCAKE_ARG_REFERENCE 2)
(define PANCAKE_ARG_INTEGER 3)
(define PANCAKE_ARG_BOOL 4)
(define PANCAKE_ARG_STRING 5)
(define PANCAKE_ARG_VOID 6)
(define PANCAKE_ARG_LIST 7)

(define PANCAKE_RES_FULFILL 0)
(define PANCAKE_RES_BREAK 1)

(define PANCAKE_ABORT_REASON_GRACEFUL_SHUTDOWN 0)
(define PANCAKE_ABORT_REASON_VERSION_MISMATCH 1)
(define PANCAKE_ABORT_REASON_PROTOCOL_ERROR 3)

;; PancakeEventKind values mirror event_callback::PancakeEventKind
;; (#[repr(u32)]) in crates/ffi/pancake-ffi-runtime/src/event_callback.rs. The
;; Rust enum is the source of truth — if these drift, peek-event-kind
;; lies. Inbound op:abort has its own AbortReceived discriminator
;; (= 6) per the post-C2 follow-up; SessionAborted (= 3) is the
;; symmetric OUTBOUND-abort discriminator (this side projecting the
;; abort).
(define PANCAKE_EVENT_KIND_PEER_READY 0)
(define PANCAKE_EVENT_KIND_PEER_CLOSED 1)
(define PANCAKE_EVENT_KIND_SESSION_ESTABLISHED 2)
(define PANCAKE_EVENT_KIND_SESSION_ABORTED 3)
(define PANCAKE_EVENT_KIND_DELIVER_RECEIVED 4)
(define PANCAKE_EVENT_KIND_RESOLVE_RECEIVED 5)
(define PANCAKE_EVENT_KIND_ABORT_RECEIVED 6)

;; ─── Cstructs ──────────────────────────────────────────────────────

;; All payloads sized to fit the largest variant on LP64. See header
;; comment about the cstruct paddings; if porting to ILP32 / Windows
;; these need a re-audit.

(define-cstruct _PancakeFrame
  ([bytes _pointer]
   [len _size]))

;; Arrow/DLPack-style managed frame: bytes/len + an embedded release
;; callback (+ opaque private_data). LP64: 8+8+8+8 = 32 bytes.
(define-cstruct _PancakeManagedFrame
  ([bytes _pointer]
   [len _size]
   [release _fpointer]
   [private_data _pointer]))

(define-cstruct _PancakeStepOutcome
  ([kind _uint32]
   [next_deadline_ms _uint64]))

;; PancakeReferencePayload = union, 32 bytes on LP64. We represent it
;; as a fixed-size byte buffer the variant builders fill in.
(define PANCAKE_REFERENCE_PAYLOAD_SIZE 32)
(define-cstruct _PancakeReference
  ([kind _uint32]
   [_padding _uint32]
   [payload (_array _uint8 PANCAKE_REFERENCE_PAYLOAD_SIZE)]))

;; PancakeArgumentPayload = union, 40 bytes (sized for PancakeReference).
(define PANCAKE_ARGUMENT_PAYLOAD_SIZE 40)
(define-cstruct _PancakeArgument
  ([kind _uint32]
   [_padding _uint32]
   [payload (_array _uint8 PANCAKE_ARGUMENT_PAYLOAD_SIZE)]))

;; PancakeResolutionPayload = union, 48 bytes (sized for PancakeArgument).
(define PANCAKE_RESOLUTION_PAYLOAD_SIZE 48)
(define-cstruct _PancakeResolution
  ([kind _uint32]
   [_padding _uint32]
   [payload (_array _uint8 PANCAKE_RESOLUTION_PAYLOAD_SIZE)]))

;; ─── Library metadata ──────────────────────────────────────────────

(define-pancake pancake-version
  (_fun -> _string)
  #:c-id pancake_version)

;; ─── Lifecycle ─────────────────────────────────────────────────────

(define-pancake pancake-peer-new-raw
  (_fun _pointer _uint32 -> _pointer)
  #:c-id pancake_peer_new)

;; Typed opinionated constructor (A2/A3 redesign):
;;   keypair — PancakeKeyPair handle (REQUIRED). The peer takes
;;             ownership; callers MUST NOT call pancake-keypair-free on
;;             it after a successful return — it's freed as part of
;;             pancake-peer-free. (Constructor failure does NOT
;;             transfer ownership; the caller is still responsible.)
;;   codec   — PANCAKE_CODEC_CAPNP | PANCAKE_CODEC_SYRUP.
;; Picks CaptpVersion::V1_0 + WireProfile::goblins_v1_0 (what every
;; production OCapN peer speaks); my-peer-id derives from the
;; keypair's pubkey via SHA² per ADR-0015; partner-peer-id is learned
;; from the handshake.
;; Returns an opaque PancakePeer pointer; raises on failure.
(define (pancake-peer-new keypair [codec PANCAKE_CODEC_SYRUP])
  (define p (pancake-peer-new-raw keypair codec))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-peer-new
             "pancake_peer_new returned NULL; last error: ~a"
             (pancake-last-error))
      p))

(define-pancake pancake-peer-new-advanced-raw
  (_fun _string _string _uint32 _uint32 _pointer -> _pointer)
  #:c-id pancake_peer_new_advanced)

;; Escape-hatch constructor (A2/A3 redesign — see the C ABI doc
;; on pancake_peer_new_advanced for the full contract):
;;   my-id-or-#f       — cstring stub label (ASCII-padded to 32 bytes)
;;                       or #f to derive from keypair-or-#f
;;   partner-id-or-#f  — cstring stub label or #f to defer to handshake
;;   codec             — PANCAKE_CODEC_CAPNP | PANCAKE_CODEC_SYRUP
;;   captp-version     — PANCAKE_CAPTP_VERSION_V1_0 | _PRESPEC
;;                       (PreSpec is the back door for property tests
;;                       + pancake↔pancake fixtures)
;;   keypair-or-#f     — PancakeKeyPair handle or #f for stub-keyed
;;                       (in-process pancake↔pancake only; real OCapN
;;                       verifiers reject stub-keyed handshakes)
;;
;; When keypair-or-#f is a real handle, the peer takes ownership the
;; same way pancake-peer-new does. When both my-id and keypair are
;; #f, raises (documented failure — no way to derive any local id).
(define (pancake-peer-new-advanced my-id-or-#f partner-id-or-#f
                                   codec captp-version
                                   [keypair-or-#f #f])
  (define p (pancake-peer-new-advanced-raw
              my-id-or-#f partner-id-or-#f
              codec captp-version (or keypair-or-#f #f)))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-peer-new-advanced
             "pancake_peer_new_advanced returned NULL; last error: ~a"
             (pancake-last-error))
      p))

(define-pancake pancake-peer-get-my-peer-id-raw
  (_fun _pointer _bytes -> _int32)
  #:c-id pancake_peer_get_my_peer_id)

;; Returns the local peer's canonical 32-byte PeerId as fresh Racket
;; bytes (the SHA²-of-pubkey derivation per ADR-0015). Available
;; immediately after pancake-peer-new; no handshake required.
;; Raises if the peer was constructed via the stub-keyed escape
;; hatch (pancake-peer-new-advanced with #f keypair) — no canonical
;; local pubkey to derive from in that case.
(define (pancake-peer-get-my-peer-id peer)
  (define out (make-bytes 32 0))
  (define rc (pancake-peer-get-my-peer-id-raw peer out))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-get-my-peer-id
           "rc=~a; last error: ~a" rc (pancake-last-error)))
  out)

(define-pancake pancake-peer-get-partner-peer-id-raw
  (_fun _pointer _bytes -> _int32)
  #:c-id pancake_peer_get_partner_peer_id)

;; Returns the partner peer's canonical 32-byte PeerId as fresh
;; Racket bytes, OR #f if the handshake hasn't completed yet
;; (PANCAKE_ERR_HANDSHAKE_INCOMPLETE). Call from inside a
;; SessionEstablished handler to get the canonical bytes; for
;; stub-keyed peers the returned bytes are the ASCII-padded
;; partner-id-cstr placeholder rather than canonical SHA² bytes.
(define (pancake-peer-get-partner-peer-id peer)
  (define out (make-bytes 32 0))
  (define rc (pancake-peer-get-partner-peer-id-raw peer out))
  (cond
    [(= rc PANCAKE_OK) out]
    [(= rc PANCAKE_ERR_HANDSHAKE_INCOMPLETE) #f]
    [else (error 'pancake-peer-get-partner-peer-id
                 "rc=~a; last error: ~a" rc (pancake-last-error))]))

(define-pancake pancake-peer-free
  (_fun _pointer -> _void)
  #:c-id pancake_peer_free)

(define-pancake pancake-peer-shutdown
  (_fun _pointer -> _void)
  #:c-id pancake_peer_shutdown)

(define-pancake pancake-peer-register-bootstrap-cap-raw
  (_fun _pointer _bytes _size _uint64 -> _int32)
  #:c-id pancake_peer_register_bootstrap_cap)

;; Register a local export (export-id) at swissnum so partners can
;; resolve it via op:deliver to <desc:export 0> 'fetch.
(define (pancake-peer-register-bootstrap-cap peer swissnum-bytes export-id)
  (define rc
    (pancake-peer-register-bootstrap-cap-raw
      peer swissnum-bytes (bytes-length swissnum-bytes) export-id))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-register-bootstrap-cap
           "rc=~a; last error: ~a" rc (pancake-last-error)))
  rc)

(define-pancake pancake-peer-register-export-raw
  (_fun _pointer _uint64 -> _int32)
  #:c-id pancake_peer_register_export)

;; Register a local export (export-id) WITHOUT a swissnum mapping.
;; Use this for caps that are reachable only by reference-passing
;; (returned in op:resolve or passed as op:deliver args), not by
;; bootstrap-fetch. Bindings hosting actors call this when an
;; actor returns a fresh cap. Idempotent.
(define (pancake-peer-register-export peer export-id)
  (define rc (pancake-peer-register-export-raw peer export-id))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-register-export
           "rc=~a; last error: ~a" rc (pancake-last-error)))
  rc)

;; ─── Per-peer step + queues ────────────────────────────────────────

(define-pancake pancake-peer-step-raw
  (_fun _pointer _PancakeStepOutcome-pointer -> _int32)
  #:c-id pancake_peer_step)

;; Returns (values kind next-deadline-ms).
(define (pancake-peer-step peer)
  (define outcome (make-PancakeStepOutcome 0 0))
  (define rc (pancake-peer-step-raw peer outcome))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-step "rc=~a; last error: ~a" rc (pancake-last-error)))
  (values (PancakeStepOutcome-kind outcome)
          (PancakeStepOutcome-next_deadline_ms outcome)))

;; ─── Inbound feed: one verb, zero-copy borrow ──────────────────────
;;
;; The runtime decodes + dispatches DIRECTLY over the caller's bytes —
;; no owned-Frame copy, no inbound queue. The bytes are borrowed only
;; for the duration of this call (the Racket FFI pins the bytevector
;; across the call; the runtime materializes everything it keeps before
;; returning), so the caller may reuse / drop / release the buffer the
;; instant the call returns. Events are ready right after the call;
;; the following pancake-peer-step only drains outbound.
(define-pancake pancake-peer-feed-inbound-raw
  (_fun _pointer _PancakeFrame-pointer -> _int32)
  #:c-id pancake_peer_feed_inbound)

(define (pancake-peer-feed-inbound peer body-bytes)
  (define frame (make-PancakeFrame body-bytes (bytes-length body-bytes)))
  (define rc (pancake-peer-feed-inbound-raw peer frame))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-feed-inbound "rc=~a; last error: ~a" rc (pancake-last-error)))
  rc)

;; Feed inbound from a raw (ptr,len) borrow — pairs with the managed
;; read paths so an inbound frame reaches the runtime with no
;; Racket-side copy: read a managed frame off the netlayer, feed its
;; (bytes,len) here, then release the managed frame.
(define (pancake-peer-feed-inbound-ptr peer ptr len)
  (define frame (make-PancakeFrame ptr len))
  (define rc (pancake-peer-feed-inbound-raw peer frame))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-feed-inbound-ptr "rc=~a; last error: ~a" rc (pancake-last-error)))
  rc)

;; ─── Outbound take: one verb, self-describing managed frame ────────
;;
;; pancake_peer_take_outbound hands back a PancakeManagedFrame — a
;; zero-copy view into runtime-owned memory carrying its own release
;; callback (the SAME release no matter which cdylib produced it, via
;; pancake-managed-frame-release). The Racket helper copies the body
;; into a GC'd bytestring and releases the managed frame before
;; returning, so callers get the idiomatic Racket unit; advanced
;; callers wanting a ptr-threaded zero-copy write can drive the raw
;; binding + the PancakeManagedFrame-bytes/-len accessors directly.
(define-pancake pancake-peer-take-outbound-raw
  (_fun _pointer _PancakeManagedFrame-pointer -> _int32)
  #:c-id pancake_peer_take_outbound)

;; pancake_managed_frame_release is in the shared abi seam (linked into
;; every cdylib); bind it off the runtime lib. The frame's embedded
;; release points back into its producing cdylib, so this one binding
;; frees frames from the runtime AND the netlayer cdylibs.
(define-pancake pancake-managed-frame-release
  (_fun _PancakeManagedFrame-pointer -> _void)
  #:c-id pancake_managed_frame_release)

;; Returns a fresh Racket bytes (copied) of the next outbound frame
;; body, or #f if no outbound frame is pending.
(define (pancake-peer-take-outbound peer)
  (define mf (cast (malloc _PancakeManagedFrame 'atomic-interior)
                   _pointer _PancakeManagedFrame-pointer))
  (define rc (pancake-peer-take-outbound-raw peer mf))
  (cond
    [(= rc 1)
     (define len (PancakeManagedFrame-len mf))
     (define ptr (PancakeManagedFrame-bytes mf))
     (define body (make-bytes len))
     (memcpy body ptr len)
     (pancake-managed-frame-release mf)
     body]
    [(= rc 0) #f]
    [else
     (error 'pancake-peer-take-outbound
            "rc=~a; last error: ~a" rc (pancake-last-error))]))

(define-pancake pancake-peer-peek-event-kind-raw
  (_fun _pointer _pointer -> _int32)
  #:c-id pancake_peer_peek_event_kind)

;; Returns the kind discriminator (one of PANCAKE_EVENT_KIND_*) of
;; the next pending event WITHOUT consuming it, OR #f if the event
;; queue is empty. Idempotent — subsequent calls (with no
;; intervening pancake-peer-poll-event-* or pancake-peer-consume-event)
;; return the same kind. Pair with pancake-peer-consume-event to drop
;; events of unhandled kinds, OR with a typed
;; pancake-peer-poll-event-* accessor on kind match.
(define (pancake-peer-peek-event-kind peer)
  (define out (malloc _uint32 'atomic-interior))
  (ptr-set! out _uint32 0)
  (define rc (pancake-peer-peek-event-kind-raw peer out))
  (cond
    [(= rc 1) (ptr-ref out _uint32 0)]
    [(= rc 0) #f]
    [else
     (error 'pancake-peer-peek-event-kind
            "rc=~a; last error: ~a" rc (pancake-last-error))]))

(define-pancake pancake-peer-consume-event-raw
  (_fun _pointer -> _int32)
  #:c-id pancake_peer_consume_event)

;; Consume (drop) the front event without projecting its payload.
;; Returns #t if an event was consumed, #f if the queue was empty.
;; Pairs with pancake-peer-peek-event-kind for the peek-then-drop
;; idiom; admissive without a prior peek (drops the next event sight
;; unseen).
(define (pancake-peer-consume-event peer)
  (define rc (pancake-peer-consume-event-raw peer))
  (cond
    [(= rc 1) #t]
    [(= rc 0) #f]
    [else
     (error 'pancake-peer-consume-event
            "rc=~a; last error: ~a" rc (pancake-last-error))]))

(define-pancake pancake-peer-session-state-raw
  (_fun _pointer _pointer -> _int32)
  #:c-id pancake_peer_session_state)

(define (pancake-peer-session-state peer)
  (define out (malloc _uint32 'atomic-interior))
  (ptr-set! out _uint32 0)
  (define rc (pancake-peer-session-state-raw peer out))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-session-state "rc=~a; last error: ~a" rc (pancake-last-error)))
  (ptr-ref out _uint32 0))

(define-pancake pancake-peer-has-outbound-raw
  (_fun _pointer -> _int32)
  #:c-id pancake_peer_has_outbound)

(define (pancake-peer-has-outbound peer)
  (= 1 (pancake-peer-has-outbound-raw peer)))

(define-pancake pancake-peer-has-event-raw
  (_fun _pointer -> _int32)
  #:c-id pancake_peer_has_event)

(define (pancake-peer-has-event peer)
  (= 1 (pancake-peer-has-event-raw peer)))

;; ─── Typed value types ─────────────────────────────────────────────

;; Racket-side projections of the C tagged unions. Each `pcake*`
;; struct's `kind` matches one of the PANCAKE_*_* constants; the
;; `payload` slot is variant-dependent (a Racket-side representation,
;; NOT the raw C bytes — translation happens at the FFI boundary).

;; PancakeReference projections.
;;   kind = PANCAKE_REF_NEAR    → payload = export-id (integer)
;;   kind = PANCAKE_REF_FAR     → payload = (vector peer-id-bytes import-id)
;;   kind = PANCAKE_REF_STURDY  → payload = (vector peer-id-bytes-or-#f swissnum-bytes)
;;   kind = PANCAKE_REF_PROMISE → payload = (vector answer-id pipeline-path-len)
;;   kind = PANCAKE_REF_BROKEN  → payload = reason-string
(struct pcakeref (kind payload) #:transparent)

(define (ref-near export-id)
  (pcakeref PANCAKE_REF_NEAR export-id))
(define (ref-far peer-id-bytes import-id)
  (unless (and (bytes? peer-id-bytes) (= (bytes-length peer-id-bytes) 32))
    (error 'ref-far "peer-id-bytes must be 32 bytes; got ~v" peer-id-bytes))
  (pcakeref PANCAKE_REF_FAR (vector peer-id-bytes import-id)))
(define (ref-sturdy peer-id-bytes swissnum-bytes)
  (pcakeref PANCAKE_REF_STURDY (vector peer-id-bytes swissnum-bytes)))

;; PancakeArgument projections.
;;   kind = PANCAKE_ARG_SYMBOL    → payload = string
;;   kind = PANCAKE_ARG_BYTES     → payload = bytes
;;   kind = PANCAKE_ARG_REFERENCE → payload = pcakeref
;;   kind = PANCAKE_ARG_INTEGER   → payload = integer (i64)
;;   kind = PANCAKE_ARG_BOOL      → payload = boolean
;;   kind = PANCAKE_ARG_STRING    → payload = string
;;   kind = PANCAKE_ARG_VOID      → payload = #f
(struct pcakearg (kind payload) #:transparent)

(define (arg-symbol s) (pcakearg PANCAKE_ARG_SYMBOL s))
(define (arg-bytes b) (pcakearg PANCAKE_ARG_BYTES b))
(define (arg-reference r) (pcakearg PANCAKE_ARG_REFERENCE r))
(define (arg-integer i) (pcakearg PANCAKE_ARG_INTEGER i))
(define (arg-bool b) (pcakearg PANCAKE_ARG_BOOL (if b #t #f)))
(define (arg-string s) (pcakearg PANCAKE_ARG_STRING s))
(define (arg-void) (pcakearg PANCAKE_ARG_VOID #f))
;; Recursive list arg; payload is a Racket list of pcakearg.
;; Nested lists are admitted (the FFI's projection walks the
;; tree).
(define (arg-list items) (pcakearg PANCAKE_ARG_LIST items))

;; PancakeResolution projections.
;;   kind = PANCAKE_RES_FULFILL → payload = pcakearg
;;   kind = PANCAKE_RES_BREAK   → payload = reason-string
(struct pcakeres (kind payload) #:transparent)

(define (res-fulfill arg) (pcakeres PANCAKE_RES_FULFILL arg))
(define (res-break reason) (pcakeres PANCAKE_RES_BREAK reason))

;; ─── Marshalling helpers (Racket pcake* → C struct bytes) ──────────

;; Allocate a malloc'd PancakeReference filled with bytes matching
;; the given pcakeref. Returns the pointer; caller is responsible
;; for keeping the pointer alive (Racket's GC manages it via
;; `malloc 'atomic`).
(define (alloc-reference! r)
  ;; Tag the malloc'd raw pointer with the cstruct's type via cast so
  ;; later operations that round-trip the value through Racket's
  ;; cstruct-contract layer (e.g. _PancakeReference-pointer-typed
  ;; argument positions on the FFI binding) see a properly-tagged
  ;; pointer. Without the cast, racket 8.16's auto-generated
  ;; set-PancakeReference-kind! rejects the value with a contract
  ;; violation; raw ptr-set! sidesteps the symptom but leaves the
  ;; pointer untagged everywhere downstream.
  (define p (cast (malloc _PancakeReference 'atomic-interior)
                  _pointer
                  _PancakeReference-pointer))
  (set-PancakeReference-kind! p (pcakeref-kind r))
  (set-PancakeReference-_padding! p 0)
  (case (pcakeref-kind r)
    [(0) ; PANCAKE_REF_NEAR
     ;; payload: uint64 export_id at offset 0
     (ptr-set! (ptr-add p (PancakeReference-offsetof 'payload)) _uint64
               (pcakeref-payload r))]
    [(1) ; PANCAKE_REF_FAR
     (define v (pcakeref-payload r))
     (define peer-id (vector-ref v 0))
     (define import-id (vector-ref v 1))
     (define payload-ptr (ptr-add p (PancakeReference-offsetof 'payload)))
     ;; PancakeFarPayload: pointer (8) + size (8) + uint64 (8)
     (define peer-id-buf (malloc _uint8 32 'atomic-interior))
     (memcpy peer-id-buf peer-id 32)
     (ptr-set! payload-ptr _pointer peer-id-buf)
     (ptr-set! (ptr-add payload-ptr 8) _size 32)
     (ptr-set! (ptr-add payload-ptr 16) _uint64 import-id)]
    [(3) ; PANCAKE_REF_STURDY
     (define v (pcakeref-payload r))
     (define peer-id (vector-ref v 0))
     (define swissnum (vector-ref v 1))
     (define payload-ptr (ptr-add p (PancakeReference-offsetof 'payload)))
     (cond
       [(and (bytes? peer-id) (= (bytes-length peer-id) 32))
        (define peer-id-buf (malloc _uint8 32 'atomic-interior))
        (memcpy peer-id-buf peer-id 32)
        (ptr-set! payload-ptr _pointer peer-id-buf)
        (ptr-set! (ptr-add payload-ptr 8) _size 32)]
       [else
        (ptr-set! payload-ptr _pointer #f)
        (ptr-set! (ptr-add payload-ptr 8) _size 0)])
     (define swiss-buf (malloc _uint8 (bytes-length swissnum) 'atomic-interior))
     (memcpy swiss-buf swissnum (bytes-length swissnum))
     (ptr-set! (ptr-add payload-ptr 16) _pointer swiss-buf)
     (ptr-set! (ptr-add payload-ptr 24) _size (bytes-length swissnum))]
    [else
     (error 'alloc-reference!
            "unsupported reference kind ~a in send-side projection (Promise / Broken are receive-only)"
            (pcakeref-kind r))])
  p)

;; PancakeReference struct offsetof helper. cstruct doesn't auto-export
;; a get-offset; compute it: kind (4) + pad (4) = 8.
(define (PancakeReference-offsetof field)
  (case field
    [(kind) 0]
    [(payload) 8]
    [else (error 'PancakeReference-offsetof "unknown field ~a" field)]))

;; Allocate a malloc'd PancakeArgument filled with bytes matching the
;; given pcakearg. Same notes as alloc-reference!. Uses raw ptr-set!
;; (not cstruct setters) — see alloc-resolution! for the reason.
(define (alloc-argument! a)
  ;; cast: see alloc-reference! for why.
  (define p (cast (malloc _PancakeArgument 'atomic-interior)
                  _pointer
                  _PancakeArgument-pointer))
  (set-PancakeArgument-kind! p (pcakearg-kind a))
  (set-PancakeArgument-_padding! p 0)
  (define payload-ptr (ptr-add p 8))
  (case (pcakearg-kind a)
    [(0) ; PANCAKE_ARG_SYMBOL
     (define b (string->bytes/utf-8 (pcakearg-payload a)))
     (define buf (malloc _uint8 (bytes-length b) 'atomic-interior))
     (memcpy buf b (bytes-length b))
     (ptr-set! payload-ptr _pointer buf)
     (ptr-set! (ptr-add payload-ptr 8) _size (bytes-length b))]
    [(1) ; PANCAKE_ARG_BYTES
     (define b (pcakearg-payload a))
     (define buf (malloc _uint8 (bytes-length b) 'atomic-interior))
     (memcpy buf b (bytes-length b))
     (ptr-set! payload-ptr _pointer buf)
     (ptr-set! (ptr-add payload-ptr 8) _size (bytes-length b))]
    [(2) ; PANCAKE_ARG_REFERENCE
     ;; Embedded reference value; copy the PancakeReference bytes
     ;; directly into the argument's payload union.
     (define refptr (alloc-reference! (pcakearg-payload a)))
     (memcpy payload-ptr refptr (ctype-sizeof _PancakeReference))]
    [(3) ; PANCAKE_ARG_INTEGER
     (ptr-set! payload-ptr _int64 (pcakearg-payload a))]
    [(4) ; PANCAKE_ARG_BOOL
     (ptr-set! payload-ptr _uint8 (if (pcakearg-payload a) 1 0))]
    [(5) ; PANCAKE_ARG_STRING
     (define b (string->bytes/utf-8 (pcakearg-payload a)))
     (define buf (malloc _uint8 (bytes-length b) 'atomic-interior))
     (memcpy buf b (bytes-length b))
     (ptr-set! payload-ptr _pointer buf)
     (ptr-set! (ptr-add payload-ptr 8) _size (bytes-length b))]
    [(6) ; PANCAKE_ARG_VOID
     ;; Discriminator-only; payload is don't-care. Zero it.
     (ptr-set! payload-ptr _uint64 0)]
    [(7) ; PANCAKE_ARG_LIST
     ;; PancakeListPayload: items (ptr, 8) + count (size, 8).
     ;; Recursive: alloc-arguments! walks the items via
     ;; alloc-argument! per element, which recurses on nested lists.
     (define-values (items-ptr count) (alloc-arguments! (pcakearg-payload a)))
     (ptr-set! payload-ptr _pointer (or items-ptr #f))
     (ptr-set! (ptr-add payload-ptr 8) _size count)]
    [else
     (error 'alloc-argument! "unsupported argument kind ~a" (pcakearg-kind a))])
  p)

;; Allocate a malloc'd array of N PancakeArguments. Returns the
;; pointer to args[0]; len arg is the array length.
(define (alloc-arguments! args)
  (define n (length args))
  (cond
    [(zero? n) (values #f 0)]
    [else
     (define arr (malloc _PancakeArgument n 'atomic-interior))
     (for ([a (in-list args)] [i (in-naturals)])
       (define src (alloc-argument! a))
       (memcpy (ptr-add arr (* i (ctype-sizeof _PancakeArgument)))
               src (ctype-sizeof _PancakeArgument)))
     (values arr n)]))

;; Allocate a malloc'd PancakeResolution. Uses raw ptr-set!
;; instead of cstruct setters because the auto-generated
;; set-PancakeResolution-kind! contract rejects malloc'd raw
;; pointers in some Racket versions.
(define (alloc-resolution! r)
  ;; cast: see alloc-reference! for why.
  (define p (cast (malloc _PancakeResolution 'atomic-interior)
                  _pointer
                  _PancakeResolution-pointer))
  (set-PancakeResolution-kind! p (pcakeres-kind r))
  (set-PancakeResolution-_padding! p 0)
  (define payload-ptr (ptr-add p 8))
  (case (pcakeres-kind r)
    [(0) ; PANCAKE_RES_FULFILL
     (define argptr (alloc-argument! (pcakeres-payload r)))
     (memcpy payload-ptr argptr (ctype-sizeof _PancakeArgument))]
    [(1) ; PANCAKE_RES_BREAK
     (define b (string->bytes/utf-8 (pcakeres-payload r)))
     (define buf (malloc _uint8 (bytes-length b) 'atomic-interior))
     (memcpy buf b (bytes-length b))
     (ptr-set! payload-ptr _pointer buf)
     (ptr-set! (ptr-add payload-ptr 8) _size (bytes-length b))]
    [else
     (error 'alloc-resolution! "unsupported resolution kind ~a" (pcakeres-kind r))])
  p)

;; ─── Receive-side projection (C struct bytes → Racket pcake*) ──────

;; The receive side reads bytes pancake-ffi wrote into out-params.
;; pancake-ffi allocates Box::into_raw'd buffers the caller must
;; free via the matching pancake_typed_*_free helper. The Racket
;; wrapper does the projection AND calls the free helper before
;; returning, so callers never see raw pointers.

(define-pancake pancake-typed-args-free
  (_fun _pointer _size -> _void)
  #:c-id pancake_typed_args_free)

(define-pancake pancake-typed-resolution-free
  (_fun _pointer -> _void)
  #:c-id pancake_typed_resolution_free)

(define-pancake pancake-typed-abort-message-free
  (_fun _pointer _size -> _void)
  #:c-id pancake_typed_abort_message_free)

(define-pancake pancake-typed-partner-locator-free
  (_fun _pointer _size -> _void)
  #:c-id pancake_typed_partner_locator_free)

(define (project-reference-from-ptr ptr)
  (define kind (ptr-ref ptr _uint32 0))
  (define payload-ptr (ptr-add ptr 8))
  (case kind
    [(0) ; PANCAKE_REF_NEAR
     (pcakeref PANCAKE_REF_NEAR (ptr-ref payload-ptr _uint64 0))]
    [(1) ; PANCAKE_REF_FAR
     (define peer-ptr (ptr-ref payload-ptr _pointer 0))
     (define peer-len (ptr-ref (ptr-add payload-ptr 8) _size 0))
     (define import-id (ptr-ref (ptr-add payload-ptr 16) _uint64 0))
     (define peer-bytes (make-bytes peer-len))
     (memcpy peer-bytes peer-ptr peer-len)
     (pcakeref PANCAKE_REF_FAR (vector peer-bytes import-id))]
    [(2) ; PANCAKE_REF_PROMISE
     (define ans (ptr-ref payload-ptr _uint64 0))
     (define plen (ptr-ref (ptr-add payload-ptr 8) _size 0))
     (pcakeref PANCAKE_REF_PROMISE (vector ans plen))]
    [(3) ; PANCAKE_REF_STURDY
     (define peer-ptr (ptr-ref payload-ptr _pointer 0))
     (define peer-len (ptr-ref (ptr-add payload-ptr 8) _size 0))
     (define swiss-ptr (ptr-ref (ptr-add payload-ptr 16) _pointer 0))
     (define swiss-len (ptr-ref (ptr-add payload-ptr 24) _size 0))
     (define peer-bytes
       (if (zero? peer-len)
           #f
           (let ([b (make-bytes peer-len)])
             (memcpy b peer-ptr peer-len) b)))
     (define swiss-bytes (make-bytes swiss-len))
     (memcpy swiss-bytes swiss-ptr swiss-len)
     (pcakeref PANCAKE_REF_STURDY (vector peer-bytes swiss-bytes))]
    [(4) ; PANCAKE_REF_BROKEN
     (define reason-ptr (ptr-ref payload-ptr _pointer 0))
     (define reason-len (ptr-ref (ptr-add payload-ptr 8) _size 0))
     (define b (make-bytes reason-len))
     (memcpy b reason-ptr reason-len)
     (pcakeref PANCAKE_REF_BROKEN (bytes->string/utf-8 b))]
    [else (error 'project-reference-from-ptr "unknown kind ~a" kind)]))

(define (project-argument-from-ptr ptr)
  (define kind (ptr-ref ptr _uint32 0))
  (define payload-ptr (ptr-add ptr 8))
  (case kind
    [(0) ; SYMBOL
     (define p (ptr-ref payload-ptr _pointer 0))
     (define l (ptr-ref (ptr-add payload-ptr 8) _size 0))
     (define b (make-bytes l)) (memcpy b p l)
     (pcakearg PANCAKE_ARG_SYMBOL (bytes->string/utf-8 b))]
    [(1) ; BYTES
     (define p (ptr-ref payload-ptr _pointer 0))
     (define l (ptr-ref (ptr-add payload-ptr 8) _size 0))
     (define b (make-bytes l)) (memcpy b p l)
     (pcakearg PANCAKE_ARG_BYTES b)]
    [(2) ; REFERENCE
     (pcakearg PANCAKE_ARG_REFERENCE (project-reference-from-ptr payload-ptr))]
    [(3) ; INTEGER
     (pcakearg PANCAKE_ARG_INTEGER (ptr-ref payload-ptr _int64 0))]
    [(4) ; BOOL
     (pcakearg PANCAKE_ARG_BOOL (not (zero? (ptr-ref payload-ptr _uint8 0))))]
    [(5) ; STRING
     (define p (ptr-ref payload-ptr _pointer 0))
     (define l (ptr-ref (ptr-add payload-ptr 8) _size 0))
     (define b (make-bytes l)) (memcpy b p l)
     (pcakearg PANCAKE_ARG_STRING (bytes->string/utf-8 b))]
    [(6) ; VOID
     (pcakearg PANCAKE_ARG_VOID #f)]
    [(7) ; LIST
     ;; PancakeListPayload: items (ptr) + count (size).
     (define items-ptr (ptr-ref payload-ptr _pointer 0))
     (define count (ptr-ref (ptr-add payload-ptr 8) _size 0))
     (cond
       [(or (zero? count) (not items-ptr))
        (pcakearg PANCAKE_ARG_LIST '())]
       [else
        (define sz (ctype-sizeof _PancakeArgument))
        (pcakearg PANCAKE_ARG_LIST
                  (for/list ([i (in-range count)])
                    (project-argument-from-ptr (ptr-add items-ptr (* i sz)))))])]
    [else (error 'project-argument-from-ptr "unknown kind ~a" kind)]))

(define (project-resolution-from-ptr ptr)
  (define kind (ptr-ref ptr _uint32 0))
  (define payload-ptr (ptr-add ptr 8))
  (case kind
    [(0) ; FULFILL
     (pcakeres PANCAKE_RES_FULFILL (project-argument-from-ptr payload-ptr))]
    [(1) ; BREAK
     (define p (ptr-ref payload-ptr _pointer 0))
     (define l (ptr-ref (ptr-add payload-ptr 8) _size 0))
     (define b (make-bytes l)) (memcpy b p l)
     (pcakeres PANCAKE_RES_BREAK (bytes->string/utf-8 b))]
    [else (error 'project-resolution-from-ptr "unknown kind ~a" kind)]))

;; ─── Typed send ────────────────────────────────────────────────────

(define-pancake pancake-peer-send-deliver-raw
  (_fun _pointer _pointer _pointer _size _uint64 -> _int32)
  #:c-id pancake_peer_send_deliver)

(define (pancake-peer-send-deliver peer target-ref args [answer-id 0])
  (define targ-ptr (alloc-reference! target-ref))
  (define-values (args-ptr n-args) (alloc-arguments! args))
  (define rc
    (pancake-peer-send-deliver-raw peer targ-ptr args-ptr n-args answer-id))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-send-deliver
           "rc=~a; last error: ~a" rc (pancake-last-error)))
  rc)

(define-pancake pancake-peer-send-resolve-raw
  (_fun _pointer _uint64 _pointer -> _int32)
  #:c-id pancake_peer_send_resolve)

(define (pancake-peer-send-resolve peer answer-id resolution)
  (define res-ptr (alloc-resolution! resolution))
  (define rc (pancake-peer-send-resolve-raw peer answer-id res-ptr))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-send-resolve "rc=~a; last error: ~a" rc (pancake-last-error)))
  rc)

(define-pancake pancake-peer-send-start-session-raw
  (_fun _pointer _string _string -> _int32)
  #:c-id pancake_peer_send_start_session)

;; Collapsed (A2/A3 redesign) — one entry point for both
;; production-signed and stub-keyed handshakes; whether the outbound
;; StartSession is signed depends on whether the peer was constructed
;; with a keypair. transport + designator are the two halves of the
;; PeerLocator this peer advertises as `acceptable_location`:
;;   transport — "tcp-testing-only", "tcp-tls", "iroh", "memory", ...
;;   designator — transport-specific address (e.g. "127.0.0.1:22050"
;;                for tcp-testing-only).
;; Both are required (cheaper than special-casing NULL admission;
;; in-process pair fixtures synthesize a placeholder designator).
(define (pancake-peer-send-start-session peer transport designator)
  (define rc (pancake-peer-send-start-session-raw peer transport designator))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-send-start-session
           "rc=~a; last error: ~a" rc (pancake-last-error)))
  rc)

;; ─── Ed25519 keypair + production StartSession ────────────────────

(define-pancake pancake-keypair-new
  (_fun -> _pointer)
  #:c-id pancake_keypair_new)

(define-pancake pancake-keypair-from-seed-raw
  (_fun _bytes _size -> _pointer)
  #:c-id pancake_keypair_from_seed)

;; seed-bytes must be exactly 32 bytes; returns an opaque PancakeKeyPair
;; pointer or #f on rejection.
(define (pancake-keypair-from-seed seed-bytes)
  (unless (and (bytes? seed-bytes) (= (bytes-length seed-bytes) 32))
    (error 'pancake-keypair-from-seed
           "seed must be exactly 32 bytes; got ~v" seed-bytes))
  (define p (pancake-keypair-from-seed-raw seed-bytes 32))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-keypair-from-seed
             "pancake_keypair_from_seed returned NULL; last error: ~a"
             (pancake-last-error))
      p))

(define-pancake pancake-keypair-free
  (_fun _pointer -> _void)
  #:c-id pancake_keypair_free)

(define-pancake pancake-keypair-pubkey-raw
  (_fun _pointer _bytes -> _int32)
  #:c-id pancake_keypair_pubkey)

;; Returns the 32-byte Ed25519 pubkey as fresh Racket bytes.
(define (pancake-keypair-pubkey kp)
  (define out (make-bytes 32 0))
  (define rc (pancake-keypair-pubkey-raw kp out))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-keypair-pubkey "rc=~a; last error: ~a" rc (pancake-last-error)))
  out)

(define-pancake pancake-peer-enliven-sturdyref-raw
  (_fun _pointer _pointer -> _int32)
  #:c-id pancake_peer_enliven_sturdyref)

(define (pancake-peer-enliven-sturdyref peer sturdyref)
  (define ref-ptr (alloc-reference! sturdyref))
  (define rc (pancake-peer-enliven-sturdyref-raw peer ref-ptr))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-enliven-sturdyref "rc=~a; last error: ~a" rc (pancake-last-error)))
  rc)

(define-pancake pancake-peer-send-abort-raw
  (_fun _pointer _uint32 _bytes _size -> _int32)
  #:c-id pancake_peer_send_abort)

(define (pancake-peer-send-abort peer reason-kind message-str)
  (define b (string->bytes/utf-8 (or message-str "")))
  (define rc (pancake-peer-send-abort-raw peer reason-kind b (bytes-length b)))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-peer-send-abort "rc=~a; last error: ~a" rc (pancake-last-error)))
  rc)

;; ─── Typed receive ─────────────────────────────────────────────────

(define-pancake pancake-peer-poll-event-deliver-raw
  (_fun _pointer _pointer _pointer _pointer _pointer _pointer -> _int32)
  #:c-id pancake_peer_poll_event_deliver)

(define-pancake pancake-typed-resolve-me-desc-free
  (_fun _pointer -> _void)
  #:c-id pancake_typed_resolve_me_desc_free)

;; Returns either #f (no Deliver pending) or
;;   (list target-pcakeref args-pcakearg-list answer-id-or-#f
;;         resolve-me-desc-pcakeref-or-#f).
;; The resolve-me-desc slot carries the partner's V1.0 resolver-
;; callback descriptor (a pcakeref) when the inbound op:deliver
;; was Goblins-V1.0-shape (op:deliver-only + resolve-me-desc) —
;; the caller dispatches the reply via pancake-peer-send-deliver
;; targeting that ref. When the inbound deliver was pre-V1.0
;; shape (op:deliver with answer-id, no resolve-me-desc), the
;; slot is #f and the caller dispatches via pancake-peer-send-resolve
;; on the answer-id.
;;
;; Frees all FFI-side side allocations before returning.
(define (pancake-peer-poll-event-deliver peer)
  (define out-target (malloc _PancakeReference 'atomic-interior))
  (define out-args-ptr (malloc _pointer 'atomic-interior))
  (define out-args-count (malloc _size 'atomic-interior))
  (define out-answer-id (malloc _uint64 'atomic-interior))
  (define out-rmd (malloc _PancakeReference 'atomic-interior))
  (ptr-set! out-args-ptr _pointer #f)
  (ptr-set! out-args-count _size 0)
  (ptr-set! out-answer-id _uint64 0)
  (define rc
    (pancake-peer-poll-event-deliver-raw
      peer out-target out-args-ptr out-args-count out-answer-id out-rmd))
  (cond
    [(= rc 1)
     (define target (project-reference-from-ptr out-target))
     (define args-array-ptr (ptr-ref out-args-ptr _pointer 0))
     (define args-count (ptr-ref out-args-count _size 0))
     (define args
       (for/list ([i (in-range args-count)])
         (project-argument-from-ptr
           (ptr-add args-array-ptr (* i (ctype-sizeof _PancakeArgument))))))
     (define answer-id (ptr-ref out-answer-id _uint64 0))
     ;; The Rust side uses PANCAKE_REF_BROKEN with reason_len=0
     ;; as the absent-sentinel. Project to #f when absent;
     ;; otherwise project the descriptor (typically a Far ref to
     ;; the partner's resolver-import) and free its side
     ;; allocations. Cast the raw pointer through the cstruct
     ;; pointer type first so the kind accessor is well-typed.
     (define rmd-struct (cast out-rmd _pointer _PancakeReference-pointer))
     (define rmd-kind (PancakeReference-kind rmd-struct))
     (define resolve-me-desc
       (cond
         [(= rmd-kind PANCAKE_REF_BROKEN)
          ;; Absent sentinel; release the (NULL) Broken payload.
          (pancake-typed-resolve-me-desc-free out-rmd)
          #f]
         [else
          (define projected (project-reference-from-ptr out-rmd))
          (pancake-typed-resolve-me-desc-free out-rmd)
          projected]))
     ;; Free the args buffer.
     (pancake-typed-args-free args-array-ptr args-count)
     (list target args
           (if (zero? answer-id) #f answer-id)
           resolve-me-desc)]
    [(= rc 0) #f]
    [else
     (error 'pancake-peer-poll-event-deliver "rc=~a; last error: ~a" rc (pancake-last-error))]))

(define-pancake pancake-peer-poll-event-resolve-raw
  (_fun _pointer _pointer _pointer -> _int32)
  #:c-id pancake_peer_poll_event_resolve)

;; Returns either #f (no Resolve pending) or (list answer-id pcakeres).
(define (pancake-peer-poll-event-resolve peer)
  (define out-answer-id (malloc _uint64 'atomic-interior))
  (define out-res (malloc _PancakeResolution 'atomic-interior))
  (define rc (pancake-peer-poll-event-resolve-raw peer out-answer-id out-res))
  (cond
    [(= rc 1)
     (define ans (ptr-ref out-answer-id _uint64 0))
     (define res (project-resolution-from-ptr out-res))
     (pancake-typed-resolution-free out-res)
     (list ans res)]
    [(= rc 0) #f]
    [else
     (error 'pancake-peer-poll-event-resolve "rc=~a; last error: ~a" rc (pancake-last-error))]))

(define-pancake pancake-peer-poll-event-abort-raw
  (_fun _pointer _pointer _pointer _pointer -> _int32)
  #:c-id pancake_peer_poll_event_abort)

;; Returns either #f or (list reason-kind reason-string).
(define (pancake-peer-poll-event-abort peer)
  (define out-kind (malloc _uint32 'atomic-interior))
  (define out-msg-ptr (malloc _pointer 'atomic-interior))
  (define out-msg-len (malloc _size 'atomic-interior))
  (define rc (pancake-peer-poll-event-abort-raw peer out-kind out-msg-ptr out-msg-len))
  (cond
    [(= rc 1)
     (define kind (ptr-ref out-kind _uint32 0))
     (define ptr (ptr-ref out-msg-ptr _pointer 0))
     (define len (ptr-ref out-msg-len _size 0))
     (define b (make-bytes len)) (memcpy b ptr len)
     (pancake-typed-abort-message-free ptr len)
     (list kind (bytes->string/utf-8 b))]
    [(= rc 0) #f]
    [else
     (error 'pancake-peer-poll-event-abort "rc=~a; last error: ~a" rc (pancake-last-error))]))

(define-pancake pancake-peer-poll-event-session-established-raw
  (_fun _pointer _bytes _pointer _pointer -> _int32)
  #:c-id pancake_peer_poll_event_session_established)

;; Returns either #f or (list partner-pubkey-bytes(32) partner-locator-string).
(define (pancake-peer-poll-event-session-established peer)
  (define pubkey-buf (make-bytes 32))
  (define out-loc-ptr (malloc _pointer 'atomic-interior))
  (define out-loc-len (malloc _size 'atomic-interior))
  (define rc
    (pancake-peer-poll-event-session-established-raw
      peer pubkey-buf out-loc-ptr out-loc-len))
  (cond
    [(= rc 1)
     (define ptr (ptr-ref out-loc-ptr _pointer 0))
     (define len (ptr-ref out-loc-len _size 0))
     (define b (make-bytes len)) (memcpy b ptr len)
     (pancake-typed-partner-locator-free ptr len)
     (list (bytes-copy pubkey-buf) (bytes->string/utf-8 b))]
    [(= rc 0) #f]
    [else
     (error 'pancake-peer-poll-event-session-established
            "rc=~a; last error: ~a" rc (pancake-last-error))]))

;; ─── OCapN URI parser (C3) ─────────────────────────────────────────

;; PancakeOcapnUri cstruct mirrors crates/ffi/pancake-ffi-runtime/src/ocapn_uri.rs.
;; On LP64: 4 pointer-sized fields = 32 bytes.
(define-cstruct _PancakeOcapnUri
  ([transport_cstr _pointer]
   [designator_cstr _pointer]
   [swissnum_bytes _pointer]
   [swissnum_len _size]))

;; Racket-side projection of a parsed OCapN URI.
;;   transport   : string (transport tag, e.g. "tcp-testing-only")
;;   designator  : string (transport-specific designator)
;;   swissnum    : bytes? or #f
;;     bytes if the URI is the OCapN spec's `/s/<base64url>` sturdyref
;;     form; #f if the URI is the peer-locator form (Spritely's
;;     bootstrap-cap convention — the binding may interpret `designator`
;;     as the swissnum-as-string per Goblins's seven-caps-peer style).
(struct ocapn-uri (transport designator swissnum) #:transparent)

(define-pancake pancake-ocapn-uri-parse-raw
  (_fun _string -> _pointer)
  #:c-id pancake_ocapn_uri_parse)

(define-pancake pancake-ocapn-uri-free
  (_fun _pointer -> _void)
  #:c-id pancake_ocapn_uri_free)

;; Parse + project + free in one go; raises if the URI is malformed
;; (last-error carries the diagnostic from pancake-runtime's
;; locator_uri::UriError).
(define (pancake-ocapn-uri-parse uri-str)
  (unless (string? uri-str)
    (error 'pancake-ocapn-uri-parse "uri-str must be a string; got ~v" uri-str))
  (define ptr (pancake-ocapn-uri-parse-raw uri-str))
  (when (zero? (cast ptr _pointer _intptr))
    (error 'pancake-ocapn-uri-parse "parse failed; last error: ~a" (pancake-last-error)))
  (define parsed (cast ptr _pointer _PancakeOcapnUri-pointer))
  (define transport
    (cast (PancakeOcapnUri-transport_cstr parsed) _pointer _string))
  (define designator
    (cast (PancakeOcapnUri-designator_cstr parsed) _pointer _string))
  (define swissnum-ptr (PancakeOcapnUri-swissnum_bytes parsed))
  (define swissnum-len (PancakeOcapnUri-swissnum_len parsed))
  (define swissnum
    (if (or (zero? (cast swissnum-ptr _pointer _intptr)) (zero? swissnum-len))
        #f
        (let ([b (make-bytes swissnum-len)])
          (memcpy b swissnum-ptr swissnum-len)
          b)))
  ;; Copy strings into Racket-managed memory before freeing the FFI struct.
  (define result (ocapn-uri (string-copy transport) (string-copy designator) swissnum))
  (pancake-ocapn-uri-free ptr)
  result)

;; ─── Syrup frame probe (F1) ────────────────────────────────────────

;; PancakeFrameProbe outcomes — mirror the constants in
;; crates/ffi/pancake-ffi-runtime/src/syrup_framing.rs.
(define PANCAKE_FRAME_COMPLETE 1)
(define PANCAKE_FRAME_INCOMPLETE 0)
(define PANCAKE_FRAME_MALFORMED -1)

;; pancake_syrup_frame_probe(buf, buf_len, &out_end, max_frame_bytes)
;; Returns PANCAKE_FRAME_COMPLETE (1), INCOMPLETE (0), MALFORMED (-1),
;; or PANCAKE_ERR_NULL_POINTER (-1 from negative).
;; On COMPLETE, the integer at out_end is the byte offset where the
;; first complete frame ends (exclusive).
(define-pancake pancake-syrup-frame-probe
  (_fun _bytes _size _pointer _size -> _int32)
  #:c-id pancake_syrup_frame_probe)

;; ─── TCP endpoint — cleartext, via libpancake_ffi_net_tcp ───────────
;;
;; Per ADR-0051 the TCP netlayer FFI is a thin sync shell over the
;; pancake-net-tcp sync core (std::net + Syrup framing + cleartext).
;; These bindings come from the net-tcp lib (define-pancake-net-tcp)
;; and read failures from its own last-error slot
;; (pancake-net-tcp-last-error). The Racket helper signatures are kept
;; stable (host + port) so the captp / tcp-bridge / netlayer modules
;; need no changes — only the underlying FFI shape moved.

(define PANCAKE_ENDPOINT_TCP_ERR_IO -20)
(define PANCAKE_ENDPOINT_TCP_ERR_MALFORMED -21)
(define PANCAKE_ENDPOINT_TCP_ERR_CLOSED -22)
(define PANCAKE_ENDPOINT_TCP_ERR_WOULD_BLOCK -23)

;; pancake_endpoint_tcp_connect(host_port) -> *mut PancakeEndpointTcpConn
(define-pancake-net-tcp pancake-endpoint-tcp-connect-raw
  (_fun #:blocking? #t _string -> _pointer)
  #:c-id pancake_endpoint_tcp_connect)

(define (pancake-endpoint-tcp-connect host port)
  (define p (pancake-endpoint-tcp-connect-raw (format "~a:~a" host port)))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-endpoint-tcp-connect
             "connect to ~a:~a failed; last error: ~a"
             host port (pancake-net-tcp-last-error))
      p))

;; pancake_endpoint_tcp_listen(bind_addr, out_addr_buf, addr_cap)
;;   -> *mut PancakeEndpointTcpListener
;; (out_addr_buf reports the bound address — useful for :0; the helper
;; passes a concrete host:port so it ignores the reported value.)
(define-pancake-net-tcp pancake-endpoint-tcp-listen-raw
  (_fun _string _pointer _size -> _pointer)
  #:c-id pancake_endpoint_tcp_listen)

(define (pancake-endpoint-tcp-listen host port)
  (define p (pancake-endpoint-tcp-listen-raw (format "~a:~a" host port) #f 0))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-endpoint-tcp-listen
             "listen on ~a:~a failed; last error: ~a"
             host port (pancake-net-tcp-last-error))
      p))

;; pancake_endpoint_tcp_accept_timed(listener, timeout_ms, &out_conn) -> i32
;; Returns one of:
;;   conn pointer — a new connection was accepted
;;   'would-block — timeout fired; no connection arrived
;;   raises — for real accept failures
(define-pancake-net-tcp pancake-endpoint-tcp-accept-timed-raw
  (_fun #:blocking? #t _pointer _uint64 _pointer -> _int32)
  #:c-id pancake_endpoint_tcp_accept_timed)

(define (pancake-endpoint-tcp-accept-timed listener timeout-ms)
  (define out (malloc _pointer 'atomic-interior))
  (ptr-set! out _pointer #f)
  (define rc (pancake-endpoint-tcp-accept-timed-raw listener timeout-ms out))
  (cond
    [(zero? rc) (ptr-ref out _pointer 0)] ; PANCAKE_OK
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_WOULD_BLOCK) 'would-block]
    [else
     (error 'pancake-endpoint-tcp-accept-timed
            "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error))]))

;; Blocking accept — the sync core's `accept_timed` with timeout_ms=0
;; blocks (the new FFI surface has no separate blocking accept).
(define (pancake-endpoint-tcp-accept listener)
  (define p (pancake-endpoint-tcp-accept-timed listener 0))
  (if (eq? p 'would-block)
      (error 'pancake-endpoint-tcp-accept "blocking accept returned would-block")
      p))

;; pancake_endpoint_tcp_read_frame(conn, &out_managed) -> i32
;; The netlayer hands back a self-describing PancakeManagedFrame
;; (zero-copy view into netlayer-owned memory + embedded release).
(define-pancake-net-tcp pancake-endpoint-tcp-read-frame-raw
  (_fun #:blocking? #t _pointer _PancakeManagedFrame-pointer -> _int32)
  #:c-id pancake_endpoint_tcp_read_frame)

;; Returns one of:
;;   bytes — a complete Syrup frame (caller owns the Racket-side bytes;
;;           the managed frame is released before return)
;;   'would-block — read-timeout fired (set via set-read-timeout-ms);
;;                  endpoint stays usable, caller polls again
;;   'closed — endpoint closed (clean teardown or remote disconnect)
;;   'malformed — Syrup grammar violation; bridge must abort
;;   raises — for I/O errors and other unrecoverable failures
(define (pancake-endpoint-tcp-read-frame endpoint)
  (define mf (cast (malloc _PancakeManagedFrame 'atomic-interior)
                   _pointer _PancakeManagedFrame-pointer))
  (define rc (pancake-endpoint-tcp-read-frame-raw endpoint mf))
  (cond
    [(zero? rc) ; PANCAKE_OK
     (define len (PancakeManagedFrame-len mf))
     (define ptr (PancakeManagedFrame-bytes mf))
     (define b (make-bytes len))
     (memcpy b ptr len)
     (pancake-managed-frame-release mf)
     b]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_WOULD_BLOCK) 'would-block]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_CLOSED) 'closed]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_MALFORMED) 'malformed]
    [else
     (error 'pancake-endpoint-tcp-read-frame
            "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error))]))

;; pancake_endpoint_tcp_set_read_timeout_ms(conn, timeout_ms) -> i32
;; Pass 0 to clear (revert to blocking). Returns PANCAKE_OK or
;; error code.
(define-pancake-net-tcp pancake-endpoint-tcp-set-read-timeout-ms-raw
  (_fun _pointer _uint64 -> _int32)
  #:c-id pancake_endpoint_tcp_set_read_timeout_ms)

(define (pancake-endpoint-tcp-set-read-timeout-ms endpoint timeout-ms)
  (define rc (pancake-endpoint-tcp-set-read-timeout-ms-raw endpoint timeout-ms))
  (unless (zero? rc)
    (error 'pancake-endpoint-tcp-set-read-timeout-ms
           "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error)))
  rc)

;; pancake_endpoint_tcp_write_frame(conn, bytes, len) -> i32
(define-pancake-net-tcp pancake-endpoint-tcp-write-frame-raw
  (_fun #:blocking? #t _pointer _bytes _size -> _int32)
  #:c-id pancake_endpoint_tcp_write_frame)

(define (pancake-endpoint-tcp-write-frame endpoint frame-bytes)
  (define rc (pancake-endpoint-tcp-write-frame-raw
              endpoint frame-bytes (bytes-length frame-bytes)))
  (unless (zero? rc)
    (error 'pancake-endpoint-tcp-write-frame
           "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error)))
  rc)

;; Zero-copy write: send a raw (ptr,len) straight to the wire — same C
;; fn as write-frame, only the Racket-side marshalling differs (a raw
;; pointer instead of a copied Racket bytestring). Pairs with the
;; PancakeManagedFrame-bytes/-len accessors on a frame from
;; pancake-peer-take-outbound's raw binding, so a drained outbound
;; frame can flow to the wire with no Racket-side copy.
(define-pancake-net-tcp pancake-endpoint-tcp-write-frame-ptr-raw
  (_fun #:blocking? #t _pointer _pointer _size -> _int32)
  #:c-id pancake_endpoint_tcp_write_frame)

(define (pancake-endpoint-tcp-write-frame-ptr endpoint ptr len)
  (define rc (pancake-endpoint-tcp-write-frame-ptr-raw endpoint ptr len))
  (unless (zero? rc)
    (error 'pancake-endpoint-tcp-write-frame-ptr
           "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error)))
  rc)

;; Release a connection (FFI: pancake_endpoint_tcp_conn_close). The
;; Racket name stays `pancake-endpoint-tcp-close` so consumers are
;; unchanged.
(define-pancake-net-tcp pancake-endpoint-tcp-close
  (_fun _pointer -> _void)
  #:c-id pancake_endpoint_tcp_conn_close)

(define-pancake-net-tcp pancake-endpoint-tcp-listener-close
  (_fun _pointer -> _void)
  #:c-id pancake_endpoint_tcp_listener_close)

;; ─── TCP+TLS endpoint (stack 3) — libpancake_ffi_net_tcp ───────────
;;
;; The tcp-tls surface mirrors the cleartext surface fn-for-fn
;; (rustls StreamOwned over the same sync TCP core). Same lib +
;; last-error slot as cleartext; read_frame hands back a managed
;; frame released via the shared pancake-managed-frame-release.

(define-pancake-net-tcp pancake-endpoint-tcp-tls-connect-raw
  (_fun #:blocking? #t _string -> _pointer)
  #:c-id pancake_endpoint_tcp_tls_connect)

(define (pancake-endpoint-tcp-tls-connect host port)
  (define p (pancake-endpoint-tcp-tls-connect-raw (format "~a:~a" host port)))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-endpoint-tcp-tls-connect
             "tls connect to ~a:~a failed; last error: ~a"
             host port (pancake-net-tcp-last-error))
      p))

(define-pancake-net-tcp pancake-endpoint-tcp-tls-listen-raw
  (_fun _string _pointer _size -> _pointer)
  #:c-id pancake_endpoint_tcp_tls_listen)

(define (pancake-endpoint-tcp-tls-listen host port)
  (define p (pancake-endpoint-tcp-tls-listen-raw (format "~a:~a" host port) #f 0))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-endpoint-tcp-tls-listen
             "tls listen on ~a:~a failed; last error: ~a"
             host port (pancake-net-tcp-last-error))
      p))

(define-pancake-net-tcp pancake-endpoint-tcp-tls-accept-timed-raw
  (_fun #:blocking? #t _pointer _uint64 _pointer -> _int32)
  #:c-id pancake_endpoint_tcp_tls_accept_timed)

(define (pancake-endpoint-tcp-tls-accept-timed listener timeout-ms)
  (define out (malloc _pointer 'atomic-interior))
  (ptr-set! out _pointer #f)
  (define rc (pancake-endpoint-tcp-tls-accept-timed-raw listener timeout-ms out))
  (cond
    [(zero? rc) (ptr-ref out _pointer 0)]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_WOULD_BLOCK) 'would-block]
    [else
     (error 'pancake-endpoint-tcp-tls-accept-timed
            "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error))]))

(define (pancake-endpoint-tcp-tls-accept listener)
  (define p (pancake-endpoint-tcp-tls-accept-timed listener 0))
  (if (eq? p 'would-block)
      (error 'pancake-endpoint-tcp-tls-accept "blocking accept returned would-block")
      p))

;; TLS read — same managed surface as cleartext (one read verb).
(define-pancake-net-tcp pancake-endpoint-tcp-tls-read-frame-raw
  (_fun #:blocking? #t _pointer _PancakeManagedFrame-pointer -> _int32)
  #:c-id pancake_endpoint_tcp_tls_read_frame)

(define (pancake-endpoint-tcp-tls-read-frame endpoint)
  (define mf (cast (malloc _PancakeManagedFrame 'atomic-interior)
                   _pointer _PancakeManagedFrame-pointer))
  (define rc (pancake-endpoint-tcp-tls-read-frame-raw endpoint mf))
  (cond
    [(zero? rc)
     (define len (PancakeManagedFrame-len mf))
     (define ptr (PancakeManagedFrame-bytes mf))
     (define b (make-bytes len))
     (memcpy b ptr len)
     (pancake-managed-frame-release mf)
     b]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_WOULD_BLOCK) 'would-block]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_CLOSED) 'closed]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_MALFORMED) 'malformed]
    [else
     (error 'pancake-endpoint-tcp-tls-read-frame
            "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error))]))

(define-pancake-net-tcp pancake-endpoint-tcp-tls-set-read-timeout-ms-raw
  (_fun _pointer _uint64 -> _int32)
  #:c-id pancake_endpoint_tcp_tls_set_read_timeout_ms)

(define (pancake-endpoint-tcp-tls-set-read-timeout-ms endpoint timeout-ms)
  (define rc (pancake-endpoint-tcp-tls-set-read-timeout-ms-raw endpoint timeout-ms))
  (unless (zero? rc)
    (error 'pancake-endpoint-tcp-tls-set-read-timeout-ms
           "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error)))
  rc)

(define-pancake-net-tcp pancake-endpoint-tcp-tls-write-frame-raw
  (_fun #:blocking? #t _pointer _bytes _size -> _int32)
  #:c-id pancake_endpoint_tcp_tls_write_frame)

(define (pancake-endpoint-tcp-tls-write-frame endpoint frame-bytes)
  (define rc (pancake-endpoint-tcp-tls-write-frame-raw
              endpoint frame-bytes (bytes-length frame-bytes)))
  (unless (zero? rc)
    (error 'pancake-endpoint-tcp-tls-write-frame
           "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error)))
  rc)

;; Zero-copy TLS write (raw ptr,len). See the cleartext
;; pancake-endpoint-tcp-write-frame-ptr for the rationale.
(define-pancake-net-tcp pancake-endpoint-tcp-tls-write-frame-ptr-raw
  (_fun #:blocking? #t _pointer _pointer _size -> _int32)
  #:c-id pancake_endpoint_tcp_tls_write_frame)

(define (pancake-endpoint-tcp-tls-write-frame-ptr endpoint ptr len)
  (define rc (pancake-endpoint-tcp-tls-write-frame-ptr-raw endpoint ptr len))
  (unless (zero? rc)
    (error 'pancake-endpoint-tcp-tls-write-frame-ptr
           "rc=~a; last error: ~a" rc (pancake-net-tcp-last-error)))
  rc)

(define-pancake-net-tcp pancake-endpoint-tcp-tls-close
  (_fun _pointer -> _void)
  #:c-id pancake_endpoint_tcp_tls_conn_close)

(define-pancake-net-tcp pancake-endpoint-tcp-tls-listener-close
  (_fun _pointer -> _void)
  #:c-id pancake_endpoint_tcp_tls_listener_close)

;; ─── iroh endpoint (stacks 4 + 5) — libpancake_ffi_net_iroh ────────
;;
;; QUIC-over-iroh. Differs from TCP: the endpoint is constructed
;; standalone (UDP auto-bound; no host:port), addressed by a base32
;; EndpointId, and dialed by EndpointId + an optional direct-addr
;; "host:port" hint (loopback without discovery). read_frame hands
;; back a managed frame released via the shared
;; pancake-managed-frame-release; failures read from the iroh lib's
;; own last-error slot.

(define IROH-ID-CAP 65) ; 64 base32 chars + NUL

(define-pancake-net-iroh pancake-endpoint-iroh-new-raw
  (_fun -> _pointer)
  #:c-id pancake_endpoint_iroh_new)

(define (pancake-endpoint-iroh-new)
  (define p (pancake-endpoint-iroh-new-raw))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-endpoint-iroh-new
             "iroh endpoint construction failed; last error: ~a"
             (pancake-net-iroh-last-error))
      p))

(define-pancake-net-iroh pancake-endpoint-iroh-endpoint-id-raw
  (_fun _pointer _pointer _size -> _int32)
  #:c-id pancake_endpoint_iroh_endpoint_id)

;; Returns the endpoint's base32 EndpointId as a Racket string.
(define (pancake-endpoint-iroh-endpoint-id endpoint)
  (define buf (malloc _byte IROH-ID-CAP 'atomic-interior))
  (define rc (pancake-endpoint-iroh-endpoint-id-raw endpoint buf IROH-ID-CAP))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-endpoint-iroh-endpoint-id
           "rc=~a; last error: ~a" rc (pancake-net-iroh-last-error)))
  (cast buf _pointer _string))

(define-pancake-net-iroh pancake-endpoint-iroh-bound-addr-raw
  (_fun _pointer _pointer _size -> _int32)
  #:c-id pancake_endpoint_iroh_bound_addr)

;; Returns the endpoint's primary bound UDP address ("host:port").
(define (pancake-endpoint-iroh-bound-addr endpoint)
  (define cap 64)
  (define buf (malloc _byte cap 'atomic-interior))
  (define rc (pancake-endpoint-iroh-bound-addr-raw endpoint buf cap))
  (unless (= rc PANCAKE_OK)
    (error 'pancake-endpoint-iroh-bound-addr
           "rc=~a; last error: ~a" rc (pancake-net-iroh-last-error)))
  (cast buf _pointer _string))

(define-pancake-net-iroh pancake-endpoint-iroh-connect-raw
  (_fun #:blocking? #t _pointer _string _string -> _pointer)
  #:c-id pancake_endpoint_iroh_connect)

;; Dial by base32 EndpointId + optional direct "host:port" hint (#f
;; for discovery-based dialing).
(define (pancake-endpoint-iroh-connect endpoint partner-endpoint-id [direct-addr #f])
  (define p (pancake-endpoint-iroh-connect-raw endpoint partner-endpoint-id (or direct-addr #f)))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-endpoint-iroh-connect
             "iroh connect to ~a failed; last error: ~a"
             partner-endpoint-id (pancake-net-iroh-last-error))
      p))

(define-pancake-net-iroh pancake-endpoint-iroh-listen-raw
  (_fun _pointer -> _pointer)
  #:c-id pancake_endpoint_iroh_listen)

(define (pancake-endpoint-iroh-listen endpoint)
  (define p (pancake-endpoint-iroh-listen-raw endpoint))
  (if (zero? (cast p _pointer _intptr))
      (error 'pancake-endpoint-iroh-listen
             "iroh listen failed; last error: ~a" (pancake-net-iroh-last-error))
      p))

(define-pancake-net-iroh pancake-endpoint-iroh-accept-timed-raw
  (_fun #:blocking? #t _pointer _uint64 _pointer -> _int32)
  #:c-id pancake_endpoint_iroh_accept_timed)

(define (pancake-endpoint-iroh-accept-timed listener timeout-ms)
  (define out (malloc _pointer 'atomic-interior))
  (ptr-set! out _pointer #f)
  (define rc (pancake-endpoint-iroh-accept-timed-raw listener timeout-ms out))
  (cond
    [(zero? rc) (ptr-ref out _pointer 0)]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_WOULD_BLOCK) 'would-block]
    [else
     (error 'pancake-endpoint-iroh-accept-timed
            "rc=~a; last error: ~a" rc (pancake-net-iroh-last-error))]))

(define (pancake-endpoint-iroh-accept listener)
  (define p (pancake-endpoint-iroh-accept-timed listener 0))
  (if (eq? p 'would-block)
      (error 'pancake-endpoint-iroh-accept "blocking accept returned would-block")
      p))

(define-pancake-net-iroh pancake-endpoint-iroh-set-read-timeout-ms-raw
  (_fun _pointer _uint64 -> _int32)
  #:c-id pancake_endpoint_iroh_set_read_timeout_ms)

(define (pancake-endpoint-iroh-set-read-timeout-ms conn timeout-ms)
  (define rc (pancake-endpoint-iroh-set-read-timeout-ms-raw conn timeout-ms))
  (unless (zero? rc)
    (error 'pancake-endpoint-iroh-set-read-timeout-ms
           "rc=~a; last error: ~a" rc (pancake-net-iroh-last-error)))
  rc)

;; iroh read — same managed surface as TCP (one read verb).
(define-pancake-net-iroh pancake-endpoint-iroh-read-frame-raw
  (_fun #:blocking? #t _pointer _PancakeManagedFrame-pointer -> _int32)
  #:c-id pancake_endpoint_iroh_read_frame)

(define (pancake-endpoint-iroh-read-frame conn)
  (define mf (cast (malloc _PancakeManagedFrame 'atomic-interior)
                   _pointer _PancakeManagedFrame-pointer))
  (define rc (pancake-endpoint-iroh-read-frame-raw conn mf))
  (cond
    [(zero? rc)
     (define len (PancakeManagedFrame-len mf))
     (define ptr (PancakeManagedFrame-bytes mf))
     (define b (make-bytes len))
     (memcpy b ptr len)
     (pancake-managed-frame-release mf)
     b]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_WOULD_BLOCK) 'would-block]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_CLOSED) 'closed]
    [(= rc PANCAKE_ENDPOINT_TCP_ERR_MALFORMED) 'malformed]
    [else
     (error 'pancake-endpoint-iroh-read-frame
            "rc=~a; last error: ~a" rc (pancake-net-iroh-last-error))]))

(define-pancake-net-iroh pancake-endpoint-iroh-write-frame-raw
  (_fun #:blocking? #t _pointer _bytes _size -> _int32)
  #:c-id pancake_endpoint_iroh_write_frame)

(define (pancake-endpoint-iroh-write-frame conn frame-bytes)
  (define rc (pancake-endpoint-iroh-write-frame-raw
              conn frame-bytes (bytes-length frame-bytes)))
  (unless (zero? rc)
    (error 'pancake-endpoint-iroh-write-frame
           "rc=~a; last error: ~a" rc (pancake-net-iroh-last-error)))
  rc)

;; Zero-copy iroh write (raw ptr,len). See the cleartext
;; pancake-endpoint-tcp-write-frame-ptr for the rationale.
(define-pancake-net-iroh pancake-endpoint-iroh-write-frame-ptr-raw
  (_fun #:blocking? #t _pointer _pointer _size -> _int32)
  #:c-id pancake_endpoint_iroh_write_frame)

(define (pancake-endpoint-iroh-write-frame-ptr conn ptr len)
  (define rc (pancake-endpoint-iroh-write-frame-ptr-raw conn ptr len))
  (unless (zero? rc)
    (error 'pancake-endpoint-iroh-write-frame-ptr
           "rc=~a; last error: ~a" rc (pancake-net-iroh-last-error)))
  rc)

(define-pancake-net-iroh pancake-endpoint-iroh-conn-close
  (_fun _pointer -> _void)
  #:c-id pancake_endpoint_iroh_conn_close)

(define-pancake-net-iroh pancake-endpoint-iroh-listener-close
  (_fun _pointer -> _void)
  #:c-id pancake_endpoint_iroh_listener_close)

(define-pancake-net-iroh pancake-endpoint-iroh-close
  (_fun _pointer -> _void)
  #:c-id pancake_endpoint_iroh_close)

;; ─── Transport-ops: the netlayer-seam vtable ───────────────────────
;;
;; The five interop stacks differ at two seams (OCapN + netlayer).
;; The netlayer-seam difference between transports is exactly four
;; per-connection frame ops plus the `acceptable_location` transport
;; tag the handshake advertises. Bundling them lets ONE pump (in
;; captp.rkt / the bridges) drive cleartext TCP, TCP+TLS, or iroh
;; without per-transport forks — the netlayer hands its bundle to the
;; pump alongside each accepted/dialed connection.
;;
;;   read-frame       : conn -> bytes | 'would-block | 'closed | 'malformed
;;   write-frame      : conn bytes -> void
;;   conn-close       : conn -> void
;;   set-read-timeout : conn ms -> void
;;   transport-name   : string (OCapN `acceptable_location` transport tag)
(struct transport-ops (read-frame write-frame conn-close set-read-timeout transport-name)
  #:transparent)

(define pancake-tcp-transport-ops
  (transport-ops pancake-endpoint-tcp-read-frame
                 pancake-endpoint-tcp-write-frame
                 pancake-endpoint-tcp-close
                 pancake-endpoint-tcp-set-read-timeout-ms
                 "tcp-testing-only"))

(define pancake-tcp-tls-transport-ops
  (transport-ops pancake-endpoint-tcp-tls-read-frame
                 pancake-endpoint-tcp-tls-write-frame
                 pancake-endpoint-tcp-tls-close
                 pancake-endpoint-tcp-tls-set-read-timeout-ms
                 "tcp-tls"))

(define pancake-iroh-transport-ops
  (transport-ops pancake-endpoint-iroh-read-frame
                 pancake-endpoint-iroh-write-frame
                 pancake-endpoint-iroh-conn-close
                 pancake-endpoint-iroh-set-read-timeout-ms
                 "iroh"))

;; ─── Cross-peer ────────────────────────────────────────────────────

(define-pancake pancake-sturdyref-dedup-new
  (_fun -> _pointer)
  #:c-id pancake_sturdyref_dedup_new)

(define-pancake pancake-sturdyref-dedup-free
  (_fun _pointer -> _void)
  #:c-id pancake_sturdyref_dedup_free)

(define-pancake pancake-cross-peer-drain-relayed-resolutions
  (_fun _pointer -> _int32)
  #:c-id pancake_cross_peer_drain_relayed_resolutions)

(define-pancake pancake-cross-peer-absorb-pending-sturdyref-enlivens
  (_fun _pointer _pointer -> _int32)
  #:c-id pancake_cross_peer_absorb_pending_sturdyref_enlivens)

(define-pancake pancake-cross-peer-cache-settled-sturdyref-enlivens
  (_fun _pointer _pointer -> _int32)
  #:c-id pancake_cross_peer_cache_settled_sturdyref_enlivens)

;; ─── Last error ────────────────────────────────────────────────────

(define-pancake pancake-last-error
  (_fun -> _string)
  #:c-id pancake_last_error)

(define-pancake pancake-clear-last-error
  (_fun -> _void)
  #:c-id pancake_clear_last_error)
