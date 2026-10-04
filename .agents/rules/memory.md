---
description: "Zig glowcap memory and frame ownership: owned transfer, bounded borrow, explicit test-only copies."
globs: src/**/*.zig
paths:
  - "src/**/*.zig"
---

# glowcap — Memory and Frame Ownership

## A copy is a design event

Every allocation or copy on the wire path is forbidden, named, or measured, and
forbidden is the default. Naming one means re-deriving it against the full
option set: one durable owner may hold the value, and a prerelease world is
yours to change ([prerelease](prerelease.md)). A negligible cost off the wire
path, paid so sibling fronts keep one contract, earns its name more easily than
a micro-saving earns an asymmetry.

- Deleting a copy is a cost claim: run the `bench/` step for the path against
  the pre-change tree. Allocation budgets count allocations, not work, so a
  deleted copy plus a new growth realloc passes green.
- Every named cost has one entry in the
  [memory-ledger skill](../skills/memory-ledger/SKILL.md), and its declaration
  carries the derivation. Add an entry when a cost earns its name; delete one
  only after re-deriving its contract.
- If a caller cannot tell whether an API transfers, borrows, or copies, the API
  is wrong. Never hide allocation behind a neutral name.

## Frames and verbs

- `Frame` owns wire bytes; `FrameView` borrows them for a bounded call.
  `FrameShape.word` storage is 8-aligned with a length divisible by 8, and
  allocation alignment is tracked separately from shape.
- `Frame.initOwned` adopts storage; `Frame.view` borrows.
- `Peer.send` moves a message into the outbound queue (the canonical path);
  `Peer.sendCopying` is the one named boundary copy for borrowed or static data.
- `Peer.feedOwned` consumes its frame on every outcome; `Peer.recvBorrowed`
  dispatches during the call and retains no borrow.
- `Peer.emitAbortForError` commits an `op:abort` through
  `Peer.commitAbortOutbound`, bypassing `recordSend`, because a refused session
  always admits its abort. Its diagnostic is a borrowed static string, and a
  delivery failure is retained in `AbortInfo` while the original error returns.
- Copy helpers for assertions (`test/support/frame.zig`) live in
  `test/support`, never in a production module.

## Allocators

- The owner that allocates releases, with enough metadata to free correctly;
  word storage frees with word alignment.
- Resolve fallible fields and reads from a replaced union arm into locals
  before publishing an ownership-bearing aggregate. Zig result-location
  semantics may change the destination before evaluating its fields; cleanup
  must remain separate from local `errdefer` cleanup.
- No `unsafe` as an optimization shortcut.
- A map removal whose key presence is an invariant asserts it
  (`std.debug.assert(map.remove(k))`). Only a genuinely idempotent removal
  discards the result, with an inline `// idempotent:` or `// tolerant:`
  reason; `source-check` holds this in `src/`.

## Footprint

The 500k-connection destination is gated by the build (ADR-0045), so a field
added to session state is a withdrawal from it. The comptime size pins and
budget tests listed in [`docs/ladder.md`](../../docs/ladder.md) step 2 hold
`Peer`, the warmed session, `Conn`, `HostSession`, every completion-adapter
row, and the Vat. When one trips, weigh the bytes and raise the budget in the
constant and in the ladder together. Never route around the check.

Retained capacity is bounded per owner so a burst cannot pin its peak:
`steady_retain_bytes` for each peer queue, `steady_recv_scratch_bytes` for the
session's recv arena (smaller, because the session answers to the 2 KiB
core-state budget), and the Vat's `steady_*_bytes` arenas and lists.
