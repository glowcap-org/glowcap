---
id: ADR-0122
status: accepted
date: 2026-08-24
tags: [c-abi, memory, ownership, performance, bindings]
decision: "GlowcapManagedFrame carries an owned foundation.Frame in fixed opaque caller-owned words. Producing or probing a managed frame performs no descriptor allocation and no byte copy; release destroys the inline owner and clears the descriptor. Native bindings reuse one metadata scratch set per serialized Session drain."
supersedes: []
superseded_by: []
amends: [ADR-0059]
amended_by: []
---

# ADR-0122 Inline managed-frame ownership

## Context

The C ABI transfers already-owned outbound and transport frames through
`GlowcapManagedFrame`. Its former implementation allocated a second heap box
for every transferred frame merely to retain the `foundation.Frame` and its
allocator. Host drains reserved that box before inspecting the queue, so even
an empty nonblocking probe allocated and could fail. Blocking transport reads
could likewise lose an otherwise successful frame to descriptor allocation.

The payload bytes already had one complete owner. A second allocation did not
extend their lifetime or make the C boundary safer; it was metadata churn on
the wire path.

## Decision

`GlowcapManagedFrame` reserves eight opaque `size_t` words in its public C
layout. glowcap moves the native `foundation.Frame` value into those words and
publishes the existing byte pointer, length, shape, and release callback.
Compile-time assertions prove the native owner fits and is correctly aligned
on every compiled target. The word count is target-independent, so the C
declaration has one source shape while ordinary ABI size rules still follow
the target's `size_t`.

The private words are glowcap storage, not a consumer extension point. A
consumer reads only the documented frame fields and calls
`glowcap_managed_frame_release`. Release destroys the inline owner, which
returns allocator-owned or external storage through its original path, then
zeroes the complete descriptor. Null and repeated public release remain
no-ops because the public wrapper claims the callback before invoking it.

Host drains now inspect and pop their queue before constructing the infallible
descriptor. Blocking transport reads wrap a completed frame without another
failure point. No frame bytes move or copy at the ABI boundary.

TypeScript, Python, and Racket retain their named payload copy before an async
host-runtime write; their FFI lifetimes cannot safely hold the native frame
across suspension. Each Session now reuses one managed-frame, prefix, and
length scratch set under its existing serialized write gate, so empty probes
and steady drains do not allocate metadata per frame. Rust continues holding
the native descriptor across its awaited write.

## Consequences

- `GlowcapManagedFrame` is larger, but it is caller-owned bounded metadata and
  eliminates one heap allocation and one allocator failure per transferred
  frame.
- The prerelease C layout and every hand-written language mirror changed
  together; there is no released layout to migrate.
- A successful transport read or Host dequeue can no longer fail solely while
  wrapping its ownership for C.
- The opaque word count is part of the ABI and is pinned by native and wasm32
  layout generation.

## Evidence

`test/c_abi/host/close_test.zig` disables the Context allocator after enqueue
and proves `take_outbound` still succeeds and empties the queue.
`test/c_abi/frame_test.zig` pins null-safe idempotent release. The ordinary
header-parity, generated-layout, allocation, and wasm ABI layout gates run
under `zig build test`, `zig build bindings`, and
`zig build wasm-abi-layout-check`.
