---
id: ADR-0031
status: accepted
date: 2026-06-06
tags: [c_abi, memory, performance, api]
decision: "Allocation policy for the C ABI is a `PancakeContext`: an explicit, caller-owned handle that owns the allocator for a whole handle family. The simple constructors keep the library-owned allocator; the `*_in` constructors allocate a peer or netlayer — and everything it owns (managed outbound/event frames, adopted inbound frames, TCP connection/listener payloads and their buffers, the context object itself) — through one context, freed back through it. The host surface is `alloc` + `free` only (size + alignment explicit, no `realloc`); the context must outlive its handles. Teardown vocabulary is `_release` for `_new`-created handles, `_close` for endpoints."
supersedes: []
superseded_by: []
---

# ADR-0031 C ABI allocation context

## Context

A C embedder must be able to choose allocation policy for the C ABI — an arena, a
tracked heap, a guarded pool — and have *every* pancake allocation honor it, not
just some. The naive shape, a per-handle `pancake_peer_new_with_allocator`, is a
footgun: it scatters the policy across constructors, says nothing about the frames
and buffers a handle later allocates, and tempts a caller to `free` a
pancake-owned object by hand. A Zig `std.mem.Allocator` cannot cross the C ABI at
all.

This sits on three [First Principles](../../../AGENTS.md#first-principles):
*production APIs make the correct path the easy path* (one policy per handle
family, not per call); *performance is a public contract — every allocation is
forbidden, intentional, or measured* (the allocator is visible at the boundary
that allocates); and *the portable core stays sync and no-I/O; adapters own host
integration* (allocation policy is `c_abi` vocabulary, never `foundation` /
`model` / `codec` / `session` / `engine`). It generalizes the library-owned
allocation [ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md)
introduced for the netlayer handle.

## Decision

**`PancakeContext` is the explicit owner of allocation policy for a handle
family** ([`src/c_abi/mod.zig`](../../../src/c_abi/mod.zig)).
`pancake_context_new_default` routes through the library allocator;
`pancake_context_new_with_allocator` routes through host `alloc` / `free`
callbacks. The `*_in` constructors (`pancake_peer_new_in`,
`pancake_tcp_netlayer_new_in`) allocate from a context, and the simple
constructors (`pancake_peer_new`, `pancake_tcp_netlayer_new`) keep the
library-owned policy for the common caller who does not care.

**Every allocation a context-scoped handle makes frees back through that
context** — the handle object, the managed outbound and event frames, adopted
inbound frames, the TCP connection/listener payloads and their read/write
buffers, and the context object itself (allocated through the host callbacks so a
host-backed family frees entirely through host policy). The mechanism is
*derive-from-parent*: a peer keeps its allocator (`engine.Peer.allocator`), a
netlayer keeps its allocator, and every managed-frame / connection / listener
payload carries the allocator it was minted from. Release routes through the
stored allocator, so the *same* `pancake_*_release` works for both the simple and
`*_in` paths, and a frame can even move between contexts because each allocation
remembers its own origin. C callers free only through the explicit release
functions — the context is policy, never a `free` a caller invokes by hand.

**The host surface is `alloc` + `free` only**, both told the size and a
power-of-two alignment. With both sides told the size, the only sound resize
policy for an opaque host allocator is "never resize in place" (`resize` → false,
`remap` → null): it keeps every `free` size exactly equal to its `alloc` size —
correct even for a size-tracking host allocator — and never asks a relocated
block to honor the original over-alignment. A grow becomes alloc-copy-free.

**Lifetime is explicit, not reference-counted.** A host-backed context's
allocator vtable lives inside the context object, so handles borrow it; the
context must outlive every handle created in it. No hidden global, no lazy init,
no background state.

**Teardown vocabulary has exactly two verbs.** Handles and managed values created
with `_new` are `_release` (`peer`, `context`, `managed_frame`, `event`,
`netlayer`); network endpoints created with `connect` / `listen` / `accept` are
`_close` (`conn`, `listener`).

## Scope (what this does not decide)

- **No per-allocation hooks.** A context binds one `alloc` / `free` pair; pancake
  does not expose per-call tags, categories, or instrumentation seams.
- **No `realloc` / in-place resize callback.** It cannot preserve the
  size-equals-size invariant or guarantee alignment of a relocated block, so it is
  absent by construction, not deferred.
- **No reference-counted context lifetime.** The context outlives its handles by
  caller contract; pancake does not track or enforce live-handle counts.
- **No allocation policy below `c_abi`.** The core layers neither know nor name a
  `PancakeContext`; allocation policy crosses as plain C callbacks at the C ABI
  and as a `std.mem.Allocator` argument inside Zig.

## Alternatives Considered

- **Per-handle `pancake_peer_new_with_allocator`.** Rejected: scatters policy
  across constructors, silent about the frames/buffers a handle later allocates,
  and invites a caller to `free` a pancake-owned object directly.
- **Expose a `std.mem.Allocator` across the C ABI.** Rejected: a Zig allocator
  vtable cannot be named or constructed by a C host; policy must cross as plain
  `alloc` / `free` callbacks.
- **A `realloc` callback for in-place growth.** Rejected: C `realloc` does not
  preserve an over-aligned block's alignment (mirrors `std.heap.CAllocator`, which
  refuses `realloc` for over-aligned allocations), and a resize callback breaks the
  free-size-equals-alloc-size invariant a size-tracking host needs. The
  alloc-copy-free grow path is always correct and was never measured as a
  bottleneck.
- **Reference-counted contexts.** Rejected: hidden lifetime machinery; an explicit
  "context outlives its handles" contract is the boring, race-free shape.

## Consequences

- `c_abi` gains `PancakeContext` / `PancakeAllocator` and the
  `pancake_context_*` / `*_in` constructors; the C ABI handle payloads carry a
  `std.mem.Allocator`, and `pancake_tcp_netlayer_free` is renamed
  `pancake_tcp_netlayer_release` to make teardown uniform.
- `pancake.h`, `README.md`, `docs/architecture.md`, and `bindings/README.md`
  state the contract authoritatively.
- Evidence: balance and lifecycle tests over default and host-backed contexts,
  including session-table growth, outbound/event/adopted frames, `feed_owned`
  failure ownership, and a TCP loopback through a host allocator
  ([`test/c_abi/context_test.zig`](../../../test/c_abi/context_test.zig)); a C
  consumer owning every allocation through a bump arena
  ([`examples/c/context_alloc.c`](../../../examples/c/context_alloc.c)), gated
  under `zig build check`.

## Notes

- [ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md) owns the netlayer
  handle and the library-owned allocation this generalizes to a caller-chosen
  policy.
