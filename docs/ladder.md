---
type: static
description: The five milestones on the way to 1.0 and where the evidence for each one lives.
sources: []
---

# The route to 1.0

glowcap has five milestones on the way to 1.0: protocol conformance,
performance at scale, hosted applications, the C ABI and bindings, and
transport reachability. Their order matters: protocol behavior comes before
performance work, and the public APIs come before adding more ways to reach a
peer.

[The vision](vision.md) defines the destination. [What ships](shipped.md) is
the current inventory, and the [roadmap](roadmap.md) lists the unfinished work.

## What protects every milestone

The protocol core is split into one-way Zig modules. The build rejects a codec
that imports another codec, protocol code that reaches into an adapter, or
portable code that imports `std.Io` or platform calls
([ADR-0011](decisions/adr/ADR-0011-compiler-enforced-layers.md)).

## 1. Protocol conformance

glowcap checks its protocol behavior three ways:

- the upstream OCapN suite runs against the production host
- live Spritely Goblins peers call glowcap and accept calls from it, over
  test TCP, Tor onion services, and iroh
- in-tree scenarios cover message arms, failure paths, limits, and both codecs

The live checks cover calls, promises, sturdyrefs, garbage collection in both
directions, answer release, and all three roles in a three-party handoff.
Each language binding also acts as a Goblins client, recipient, and gifter,
and proves remote object reclamation before its session closes.

The milestone is met when every implemented behavior has outside-peer
evidence. [Community review](community-review.md) has the matrix of which
behaviors do.

## 2. Performance at scale

The target is 500,000 live sessions on one node.

The build holds the cost of each session and Host:

- Struct sizes are compile-time budgets. Each `*_budget_bytes` constant sits
  beside the type it limits and fails the build when the type grows.
- `test/engine/footprint_budget_test.zig` holds a warmed connection's whole
  state, and the completion-adapter tests under `test/net/` hold each
  transport's per-connection row.
- `zig build perf-check` holds ReleaseFast ceilings on a warm inbound turn, an
  answered send, and garbage-collection growth. The ceilings are constants at
  the top of `bench/dispatch_scaling_bench.zig` and
  `bench/outbound_bench.zig`. Each sits about an order of magnitude over the
  measured figure, so only a structural regression crosses it.

A busy connection can also hold two outbound buffers of
`steady_outbound_bytes` each, which matters more than protocol state when
sizing a loaded server. An idle connection holds neither, and no read buffer.

The [performance page](../site/content/performance.smd) charts the measured
footprint and round trips. [Benchmarks](../bench/README.md) records the
primitive floors each product path pays and the 500,000-session run, with the
command that repeats it.

## 3. Hosted applications

The accountability application records who invoked a hosted capability and
attributes an introduced call to the recipient, not the introducer. The rooms,
tasks, and tools applications run one session API from Zig, Rust, TypeScript,
Python, and Racket, covering setup, hosting, calls, promises, capability
passing, and handoff as an application uses them.

## 4. C ABI and bindings

The C headers are generated from Zig and checked for drift. Rust, TypeScript,
Python, and Racket consume the same ABI and archives through generated function
tables and checked layout mirrors. Each binding runs an ordinary glowcap
conversation and a live Goblins conversation through that ABI.

Those checks cover the shared session API, both application-facing handoff
roles, and both session directions. In the reciprocal listener matrix, a real
Goblins vat dials each binding, enlivens its Host-wide actor, and reads the
actor's exact reply.

## 5. Transport reachability

The [transports page](../site/content/transports.smd) lists every way to
reach a peer, and [stability](stability.md) says which platforms run which
checks. The milestone is met when every supported platform runs the
completion loop, every binding opens sessions on every transport it offers,
and a browser peer is reachable at a public hostname.
[Known limitations](boundaries.md) explains the gaps, and the
[roadmap](roadmap.md) lists the work that closes them.
