---
id: ADR-0030
status: accepted
date: 2026-06-05
tags: [net, runtime, c_abi, resilience, memory, performance]
decision: "The netlayer is a `net` layer outside the sync no-I/O core: it is the one place `std.Io` enters. A `Connection` folds the one parser (ADR-0029) over a type-erased `std.Io.Reader`/`Writer`. `tcp.zig` is the only `std.Io.net`-to-socket site. The C ABI re-exposes blocking endpoint handles over an explicit caller-owned netlayer handle (no hidden global runtime). Per-connection inbound memory is bounded by `SessionLimits.max_frame_bytes`. Slice-1 sizes the read buffer to that bound (whole-frame), and explicitly defers the small-buffer/bounded-overflow path and full-duplex backpressure."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0110, ADR-0229]
---

# ADR-0030 Netlayer connection & per-connection memory posture

> **Framing amendment (ADR-0110).** A byte-stream `Connection` now finds
> message boundaries from an outer Syrup byte string, then requires the active
> codec to consume that body exactly. The memory bound and layer ownership in
> this decision remain unchanged.

## Context

The sync, no-I/O protocol core (foundation / model / codec / session / engine)
stays deterministic and reaches no clock, socket, or scheduler
([First Principles](../../../AGENTS.md#first-principles)). A netlayer connects
that core to real sockets without moving `std.Io`, hidden allocation, or a run
loop across the boundary, and it bounds the memory an untrusted partner can make
a connection hold.

## Decision

**The netlayer is `src/net/`, outside the core.** The arch gate
([`tools/check/arch_check.zig`](../../../tools/check/arch_check.zig)) keeps the five core
layers free of `std.Io` and admits `net` as a non-core layer that may import
down to `engine` but is itself imported only by `c_abi` and the public root. It
is the one place `std.Io` enters.

**`Connection` folds the one parser over a type-erased stream.**
[`pumpOver`](../../../src/net/connection.zig) drives a `*std.Io.Reader` /
`*std.Io.Writer`: it encodes + flushes queued outbound, then applies one inbound
frame via `recvStreamPrefix` ([ADR-0029](ADR-0029-one-parser-stream-framing.md))
and `toss`es its bytes, distinguishing graceful EOF (`closed`) from mid-frame
EOF (`TruncatedFrame`). The framing core is tested with `Reader.fixed` /
`Writer.fixed`, with no socket.

**`tcp.zig` is the only `std.Io.net`-to-socket site.** It maps a locator's
`host:port` designator to a `std.Io.net.Stream` and welds it to a borrowed peer.
The host passes its chosen `std.Io` (Threaded / Uring / …). The transport name
is `tcp` (cleartext), chosen in [ADR-0035](ADR-0035-live-goblins-interop.md) so
a Goblins netlayer can address glowcap.

**The C ABI re-exposes blocking endpoint handles.** A host that owns the peer
shuttles whole frames through `glowcap_tcp_*`
(`read_frame ->
feed_owned -> step -> take_outbound -> write_frame`). The C side
cannot name a `std.Io`, so the I/O backend is an explicit owned handle: the
host creates a `GlowcapTcpNetlayer` (which owns one `std.Io.Threaded`), makes
connections and listeners from it, and frees it after closing them. There is no
process-global runtime and no lazy init. `glowcap_last_error` re-surfaces the
concrete socket cause behind a flat `GLOWCAP_ERR_IO`.

**Per-connection inbound memory is bounded by `SessionLimits.max_frame_bytes`.**
A frame whose scanned length crosses the bound is `too_large` (ADR-0029). A full
read buffer that has not yielded a frame is refused before an over-read. Slice 1
sizes the read buffer to `max_frame_bytes` so any admissible frame fits whole.
This is a loopback simplification, not the steady-state production shape.

## Scope (what this does not decide)

- **Small-buffer + bounded-overflow.** A small fixed read buffer plus a bounded
  owned-accumulation path for frames larger than the buffer, so steady
  per-connection memory stops scaling with `max_frame_bytes`. Out of slice 1
  (loopback, few connections). Decided in
  [ADR-0041](ADR-0041-bounded-inbound-spill.md).
- **Full-duplex backpressure.** A single fiber mid-`writeAll` to a slow reader
  can head-of-line-block. Request/response traffic (handshake, fetch,
  deliver/resolve) is safe on one fiber. Concurrent streaming wants split
  read/write fibers and a bounded outbound queue above `pump`. The loop half is
  decided in [ADR-0042](ADR-0042-outbound-high-water-backpressure.md). The
  blocking half is settled as a refusal in
  [ADR-0053](ADR-0053-blocking-pump-single-fiber.md).
- **TLS / QUIC / iroh / Tor and any background run loop.** Layer above the same
  `Connection` / `FrameStream` types.

The crossed-hellos path lives at the driver/adapter seam:
`driver.core.crossed_hellos` (`src/driver/core/crossed_hellos.zig`) owns the
registry and tie-break, and the engine/model layer owns only the typed abort
projection.

## Alternatives Considered

- **Netlayer inside the core.** Rejected: `std.Io` in the core breaks the sync
  no-I/O invariant and the determinism the in-process scenarios depend on.
- **A generic comptime `Endpoint` abstraction.** Rejected for slice 1: every
  byte-stream transport already funnels through `std.Io.Reader`/`Writer`, and a
  concrete `Connection` over those is simpler and testable without a socket.
- **Unbounded read buffer / grow-to-fit.** Rejected: an untrusted peer could
  force unbounded per-connection memory.
- **Expose `std.Io` across the C ABI.** Rejected: the C host cannot name a Zig
  `Io`. An explicit `GlowcapTcpNetlayer` handle that owns the backend keeps
  the seam to `ptr+len` and return codes with no hidden global runtime.
- **A process-global lazily-initialized backend.** Rejected: a global
  `std.Io.Threaded` created on first use is a hidden runtime with no teardown
  and an init race. The owned handle is explicit and freeable.

## Consequences

- `SessionLimits` gains `max_frame_bytes`. `abort_projection` maps
  `FrameTooLarge` to `resource_exhausted` + close.
- New module `src/net/` (`connection`, `tcp`, `frame_stream`). `c_abi` gains
  endpoint handles, `last_error`, and bootstrap registration. `glowcap.h` and
  `bindings/README.md` track the grown surface.
- Evidence: `Reader.fixed`/`Writer.fixed` framing tests
  ([`test/net/connection_test.zig`](../../../test/net/connection_test.zig)), the
  TCP loopback handshake + bootstrap-fetch round-trip
  ([`test/net/tcp_test.zig`](../../../test/net/tcp_test.zig)), and the C-ABI
  C frame-seam loopback under a caller allocation context
  ([`test/c_abi/context_test.zig`](../../../test/c_abi/context_test.zig)).

## Bring-your-own transport seam

The transport seam is a `*std.Io.Reader` / `*std.Io.Writer` pair.
`net.pumpOver` (and `readFrameFrom` / `writeFrameTo`) drive a peer
over any such pair, `tcp` is the built-in binding, and a non-stream transport
such as a callback or datagram API drives the peer directly through
`engine.Peer.recvStreamPrefix` and `takeOutbound`: the same path a language
binding uses over the C ABI's `glowcap_peer_recv_stream`. Bring-your-own
netlayer is a supported, tested contract: any transport that yields a reader
and writer, or that can hand the peer a byte prefix, runs a peer with no change
to the core.

## Notes

- [ADR-0029](ADR-0029-one-parser-stream-framing.md) owns the framing this folds
  over. [ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md) owns the
  handshake/bootstrap-fetch halves the connection drives without special-casing.
  [ADR-0025](ADR-0025-session-table-cap-policy.md) owns the `resource_exhausted`
  posture `FrameTooLarge` joins.
