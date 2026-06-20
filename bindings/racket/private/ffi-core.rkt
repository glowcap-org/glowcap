#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_ocapn, the core archive.
;;
;; Nothing here is public. The ergonomic surface in `../pancake.rkt` calls the
;; bound C functions and reads/writes the cstructs `ffi-shared.rkt` defines; a
;; consumer never requires this file. This loader opens ONLY libpancake_ocapn:
;; the universal base usable alone (ADR-0059). The transport archives have their
;; own loaders (`ffi-tcp.rkt`, `ffi-inproc.rkt`, `ffi-iroh.rkt`), each opening
;; only its own symbol-disjoint archive, so requiring the core pulls in no
;; transport.
;;
;; No extension on the path: `ffi-lib` appends the platform-correct one (`.so`,
;; `.dylib`, `.dll`) and tries the versioned variants, so this loads on Linux,
;; macOS, and Windows from the one `zig build` output.
(require ffi/unsafe
         ffi/unsafe/define
         racket/runtime-path
         "ffi-shared.rkt")
;; Re-export the shared cstruct vocabulary so a module that requires this loader
;; has the layouts the bound functions read and write.
(provide (all-from-out "ffi-shared.rkt")
         (all-defined-out))

(define-runtime-path ocapn-lib-path "../../../zig-out/lib/libpancake_ocapn")
(define ocapn-lib (pancake-ffi-lib "pancake_ocapn" (path->string ocapn-lib-path)))

(define-ffi-definer define-pancake ocapn-lib)
(define-pancake pancake_abi_version
  (_fun (major : (_ptr o _uint32)) (minor : (_ptr o _uint32)) (patch : (_ptr o _uint32))
        -> _void -> (values major minor patch)))
(define-pancake pancake_last_error (_fun _pointer _size -> _size))
(define-pancake pancake_clear_last_error (_fun -> _void))
(define-pancake pancake_context_new (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_context_new_with_allocator
  (_fun _PancakeAllocator-pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_context_release (_fun _pointer -> _void))
(define-pancake pancake_peer_new_in
  (_fun _pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_feed_owned (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-pancake pancake_peer_new (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_new_negotiated
  (_fun _uint32 _uint32 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_new_negotiated_in
  (_fun _pointer _uint32 _uint32 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_new_raw_open (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_new_raw_open_in
  (_fun _pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_start_session
  (_fun _pointer _pointer _size _pointer _size _uint32 _pointer _size -> _int32))
(define-pancake pancake_peer_session_is_open (_fun _pointer -> _int32))
(define-pancake pancake_peer_release (_fun _pointer -> _void))
(define-pancake pancake_peer_feed_borrowed (_fun _pointer _PancakeFrame-pointer -> _int32))
(define-pancake pancake_peer_step (_fun _pointer -> _int32))
;; Step until idle: loop `step` until both the inbound and pending-outbound
;; queues are empty, so one pump fully encodes a settlement and every message it
;; cascades (a projection resolving, a listener firing, a queued deliver). The
;; binding's single-`step` pump otherwise strands cascaded outbound behind a
;; blocking inbox read.
(define-pancake pancake_peer_step_to_idle (_fun _pointer -> _int32))
;; Pipelined projections (ADR-0050): `op:get` / `op:index` / `op:untag` against a
;; promise receiver, each allocating the projected answer the caller passes.
(define-pancake pancake_peer_send_get
  (_fun _pointer _PancakeReference-pointer _pointer _size _uint64 -> _int32))
(define-pancake pancake_peer_send_index
  (_fun _pointer _PancakeReference-pointer _int64 _uint64 -> _int32))
(define-pancake pancake_peer_send_untag
  (_fun _pointer _PancakeReference-pointer _pointer _size _uint64 -> _int32))
(define-pancake pancake_peer_recv_stream
  (_fun _pointer _pointer _size (consumed : (_ptr o _size)) -> (r : _int32) -> (values r consumed)))
(define-pancake pancake_peer_take_outbound (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-pancake pancake_managed_frame_release (_fun _PancakeManagedFrame-pointer -> _void))
(define-pancake pancake_peer_poll_event (_fun _pointer _PancakeEvent-pointer -> _int32))
(define-pancake pancake_event_release (_fun _PancakeEvent-pointer -> _void))
(define-pancake pancake_peer_register_export (_fun _pointer _uint64 -> _int32))
(define-pancake pancake_peer_next_export
  (_fun _pointer (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_register_import (_fun _pointer _uint64 -> _int32))
(define-pancake pancake_peer_next_answer
  (_fun _pointer (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_last_abort (_fun _pointer _PancakeLastAbort-pointer -> _int32))
(define-pancake pancake_peer_peek_event (_fun _pointer -> _int32))
(define-pancake pancake_peer_send_deliver
  (_fun _pointer _PancakeReference-pointer _pointer _size _uint32 _uint64 -> _int32))
(define-pancake pancake_peer_send_resolve
  (_fun _pointer _uint64 _uint32 _PancakeArgument-pointer/null _pointer _size -> _int32))
(define-pancake pancake_peer_poll_event_deliver (_fun _pointer _PancakeDeliver-pointer -> _int32))
(define-pancake pancake_peer_poll_event_resolve (_fun _pointer _PancakeResolve-pointer -> _int32))
(define-pancake pancake_deliver_release (_fun _PancakeDeliver-pointer -> _void))
(define-pancake pancake_resolve_release (_fun _PancakeResolve-pointer -> _void))
(define-pancake pancake_peer_register_bootstrap_cap
  (_fun _pointer _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_send_bootstrap_fetch
  (_fun _pointer _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
;; Sturdyref enliven (ADR-0012): the requester half over bootstrap-fetch with the
;; dedup cache. `prepare` consults the cache and, on a miss, queues the fetch;
;; `record` settles a fresh enliven once its resolution arrives.
(define-pancake pancake_peer_prepare_enliven
  (_fun _pointer _pointer _size _PancakeEnlivenStart-pointer -> _int32))
(define-pancake pancake_peer_record_enlivenment
  (_fun _pointer _pointer _size _uint32 _uint64 _uint32 -> _int32))
;; Recipient half of a three-party handoff: sign a desc:handoff-receive over the
;; verbatim give bytes (keyed by the 32-byte seed) and queue a withdraw-gift
;; deliver to the exporter's bootstrap under `answer`.
(define-pancake pancake_peer_send_withdraw_gift
  (_fun _pointer _pointer _size _pointer _size _uint64 -> _int32))
;; Gifter (introducer) half of a three-party handoff (ADR-0009/ADR-0056). A
;; gifter reads the partner's session key (the recipient key, the exporter key)
;; and the exporter's verbatim location bytes off the two sessions it holds, then
;; deposits the gift with the exporter and resolves the recipient's question with
;; a signed `desc:handoff-give` it builds from those inputs.
(define-pancake pancake_peer_partner_session_key
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_peer_partner_locator_raw
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_peer_send_deposit_gift
  (_fun _pointer _pointer _size _PancakeReference-pointer -> _int32))
(define-pancake pancake_peer_send_resolve_handoff_give
  (_fun _pointer _uint64 _pointer _size -> _int32))
(define-pancake pancake_build_handoff_give
  (_fun _pointer _size _pointer _size _pointer _size _pointer _size _pointer _size
        (give : (_ptr o _pointer)) (give-len : (_ptr o _size)) -> (r : _int32) -> (values r give give-len)))
(define-pancake pancake_handoff_give_bytes_release (_fun _pointer _size -> _void))
;; Build the verbatim exporter location-record bytes a give names (transport +
;; designator, plus optional comma-separated direct-addresses) — the
;; construct-it-yourself counterpart of `pancake_peer_partner_locator_raw` for an
;; iroh exporter reachable only by a dial hint.
(define-pancake pancake_encode_peer_locator
  (_fun _pointer _size _pointer _size _pointer _size
        (out : (_ptr o _pointer)) (out-len : (_ptr o _size)) -> (r : _int32) -> (values r out out-len)))
(define-pancake pancake_peer_locator_bytes_release (_fun _pointer _size -> _void))
;; The node: the cross-connection handoff router (engine.Node, ADR-0066) — the one
;; place the router lives, projected here so every binding shares it. Semantics
;; in `src/c_abi/ocapn/node.zig`.
(define-pancake pancake_node_new
  (_fun _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_node_new_in
  (_fun _pointer _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_node_free (_fun _pointer -> _void))
(define-pancake pancake_node_register_conn
  (_fun _pointer (cid : (_ptr o _uint64)) (peer : (_ptr o _pointer))
        -> (r : _int32) -> (values r cid peer)))
(define-pancake pancake_node_remove_conn (_fun _pointer _uint64 -> _int32))
(define-pancake pancake_node_send_withdraw
  (_fun _pointer _uint64 _pointer _size _uint64 -> _int32))
(define-pancake pancake_node_originate_give
  (_fun _pointer _uint64 _uint64 _PancakeReference-pointer _pointer _size _uint64 _pointer _size -> _int32))
(define-pancake pancake_node_enroll_redeemed
  (_fun _pointer _uint64 _uint64 (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_node_route
  (_fun _pointer _uint64 _uint64 (cid : (_ptr o _uint64)) (fid : (_ptr o _uint64)) (routed : (_ptr o _uint32))
        -> (r : _int32) -> (values r cid fid routed)))
(define-pancake pancake_node_record_foreign_home (_fun _pointer _uint64 _uint64 -> _int32))
(define-pancake pancake_node_foreign_home
  (_fun _pointer _uint64 (cid : (_ptr o _uint64)) (found : (_ptr o _uint32))
        -> (r : _int32) -> (values r cid found)))
(define-pancake pancake_node_arg_is_foreign
  (_fun _pointer _uint64 _uint64 (foreign : (_ptr o _uint32))
        -> (r : _int32) -> (values r foreign)))
(define-pancake pancake_peer_codec
  (_fun _pointer (out : (_ptr o _uint32)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_send_gc_export
  (_fun _pointer _pointer _pointer _size -> _int32))
(define-pancake pancake_peer_send_gc_answer (_fun _pointer _uint64 -> _int32))

;; OCapN locator URIs, core libpancake_ocapn vocabulary, so a TCP-only program reaches
;; the grammar without any transport companion. One grammar, no hand-rolled percent
;; codec: verbs mint an opaque locator handle, nouns read borrowed views from it.
(define-pancake pancake_uri_parse_peer
  (_fun _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_uri_parse_sturdyref
  (_fun _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_uri_format_peer
  (_fun _pointer _size _pointer _size _pointer _pointer _pointer _pointer _size
        _pointer _size (out-len : (_ptr o _size)) -> (r : _int32) -> (values r out-len)))
(define-pancake pancake_uri_format_sturdyref
  (_fun _pointer _size _pointer _size _pointer _size _pointer _pointer _pointer _pointer _size
        _pointer _size (out-len : (_ptr o _size)) -> (r : _int32) -> (values r out-len)))
(define-pancake pancake_locator_transport
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_designator
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_swissnum
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_hint
  (_fun _pointer _pointer _size (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_hint_count
  (_fun _pointer (c : (_ptr o _size)) -> (r : _int32) -> (values r c)))
(define-pancake pancake_locator_hint_at
  (_fun _pointer _size (k : (_ptr o _pointer)) (kl : (_ptr o _size)) (v : (_ptr o _pointer)) (vl : (_ptr o _size))
        -> (r : _int32) -> (values r k kl v vl)))
(define-pancake pancake_locator_release (_fun _pointer -> _void))
