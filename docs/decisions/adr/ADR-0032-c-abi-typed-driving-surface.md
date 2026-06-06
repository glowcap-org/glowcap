---
id: ADR-0032
status: accepted
date: 2026-06-06
tags: [c_abi, api, ocapn, bindings]
decision: "The C ABI gains a typed driving surface so a non-Zig binding can drive OCapN — construct an op:deliver/op:resolve and read a delivery/resolution as structured values — instead of only shuttling opaque frames. Outbound marshals fixed-layout C structs (PancakeReference/PancakeArgument) into a model message through Peer.sendCopying (the named boundary copy); inbound materializes one event into a per-event arena and projects C views aliasing it, released by a *_free. The struct layouts are frozen ABI."
supersedes: []
superseded_by: []
---

# ADR-0032 C ABI typed driving surface

## Context

The shipped C ABI ([ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md))
shuttles opaque frames: a consumer can feed wire bytes and read back the raw
bytes of a surfaced event, but it cannot *construct* a call or *read* a
delivery's target and arguments without re-implementing a codec. So every
non-Zig binding could prove the library links and that an event surfaces — not
that it drives OCapN. The north star is a binding that calls a remote method and
reads the reply. This engages the [First Principles](../../../AGENTS.md#first-principles):
the boring public surface stays C-shaped (`ptr+len`, fixed-width tags, explicit
release), and the wire-path copy is named, not hidden — the Zig engine already
owns the machinery, so this is a marshalling boundary, not new protocol.

## Decision

**A typed value vocabulary as fixed-layout `extern struct`s**
([`src/c_abi/mod.zig`](../../../src/c_abi/mod.zig), declared in
[`include/pancake.h`](../../../include/pancake.h)): `PancakeReference`
(near/far/promise/sturdy/broken + object/promise sub-kind), `PancakeArgument`
(a kind-tagged fat struct covering integer, float64, boolean, bytes, string,
symbol, void, reference, and nested list), `PancakeDeliver`, and `PancakeResolve`.
These flatten `model.Reference` / `model.Argument` / `model.Deliver` /
`model.Resolve`; **their layouts are frozen ABI.**

**Outbound borrows, the clone owns.** `pancake_peer_send_deliver` /
`_send_resolve` marshal the caller's C structs into a `model.Message` (bytes
borrowed for the call) and route through `Peer.sendCopying` — the named boundary
copy that exists for exactly this borrowed/FFI input. Temporary `model` slices
live in a per-call arena freed when the call returns; the C bytes are never
retained.

**Inbound materializes once into a per-event arena.**
`pancake_peer_poll_event_deliver` / `_poll_event_resolve` take the next event,
project it through `Event.view()` (so a V1.0 resolver-callback re-projects as the
semantic `op:resolve`), and `toOwned` it into a heap-pinned `ArenaAllocator`
whose child is the peer's allocator. The C view's pointers alias that arena;
`pancake_deliver_free` / `_resolve_free` deinit it exactly once.

**Routing without event loss.** `pancake_peer_peek_event` returns the next
event's kind without consuming it; a typed `poll_event_*` whose kind does not
match returns `PANCAKE_ERR_WRONG_EVENT` and leaves the event queued.
`pancake_peer_register_export` / `_register_import` name the positions a binding
serves or calls. Values outside the carried set (set/tagged/handoff/keyword args,
sturdy/broken targets) are refused with `PANCAKE_ERR_UNSUPPORTED_VALUE`, never
dropped — the symmetric-refusal posture of
[ADR-0003](ADR-0003-codec-interoperability-posture.md).

## Scope (what this does not decide)

- **Not the full passable tree.** set, tagged, keyword, handoff arguments, and
  sturdy/broken reference *targets* are refused loudly, not carried. The fat
  struct is kind-tagged so adding a variant does not change existing layouts.
- **No pipelining-path construction** (a promise target with a `PipelinePath`)
  and no handoff/sturdyref driving from C yet.
- **No transport.** Driving still pairs with the opaque-frame and
  `tcp-testing-only` paths for moving bytes; this ADR is the value boundary only.

## Alternatives Considered

- **Keep shuttling opaque frames; let bindings encode/decode.** Rejected: forces
  every binding to re-implement Syrup/Cap'n Proto; the C ABI exposes no codec, so
  this is not actually usable for OCapN.
- **Borrow the frame's bytes directly in the projected view.** Rejected: the
  event's frame must be released after the call; aliasing it would dangle. One
  arena per projection ties all the view's lifetimes to a single `*_free`.
- **A single `poll_event` returning a tagged union of every kind.** Rejected: a
  peek + kind-specific `poll_event_*` keeps each out-struct small and the
  ownership of each projection local to its `*_free`.

## Consequences

- `c_abi` gains the typed structs, `peek_event`, `send_deliver`/`send_resolve`,
  `poll_event_deliver`/`poll_event_resolve`, `register_export`/`register_import`,
  and the `*_free` helpers; `engine` gains `Peer.peekEventKind` (and `Queue.peek`).
- Evidence: Zig round-trips over construct, inspect, server reply, kind-routing,
  and loud refusal ([`test/c_abi/typed_test.zig`](../../../test/c_abi/typed_test.zig)).
- Every binding now ships an **idiomatic, language-native API** over the typed
  surface (a `Peer` with native value arguments and typed events), exercised by a
  real OCapN round-trip in each ([`bindings/`](../../../bindings/)).
- The hand-written `pancake.h` and the Zig `c_abi` source are kept consistent by
  a compiler-checked drift guard rather than codegen (which would strip the
  header's prose contract):
  [`test/c_abi/header_parity_test.zig`](../../../test/c_abi/header_parity_test.zig)
  `@cImport`s the header and asserts every struct size/offset and constant equals
  the Zig source, so the two redundant declarations cannot silently diverge.

## Forward compatibility

The kind-tagged structs reserve room: a new `PANCAKE_ARG_*` / `PANCAKE_REF_*`
variant extends the carried set without changing the frozen field layout, so the
deferred passables and pipelining/handoff driving land additively.

## Notes

- [ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md) owns the
  opaque-frame and netlayer surface this drives over;
  [ADR-0031](ADR-0031-c-abi-allocation-context.md) owns the allocation context
  every handle (and now every projection arena) routes through;
  [ADR-0021](ADR-0021-ocapn-value-tree-breadth.md) owns the value-tree breadth
  the carried set is a subset of.
