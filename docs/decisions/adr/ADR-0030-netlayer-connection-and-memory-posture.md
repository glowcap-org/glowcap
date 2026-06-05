---
id: ADR-0030
status: accepted
date: 2026-06-05
tags: [net_adapter, runtime, c_abi, resilience, memory, performance]
decision: "The netlayer is a `net_adapter` layer outside the sync no-I/O core: it is the one place `std.Io` enters. A `Connection` folds the one parser (ADR-0029) over a type-erased `std.Io.Reader`/`Writer`; `tcp.zig` is the only `std.Io.net`-to-socket site; the C ABI re-exposes blocking endpoint handles over an explicit caller-owned netlayer handle (no hidden global runtime). Per-connection inbound memory is bounded by `SessionLimits.max_frame_bytes`. Slice-1 sizes the read buffer to that bound (whole-frame), and explicitly defers the small-buffer/bounded-overflow path, full-duplex backpressure, and crossed-hellos."
supersedes: []
superseded_by: []
---

# ADR-0030 Netlayer connection & per-connection memory posture

## Context

The sync, no-I/O protocol core (foundation / model / codec / session / runtime)
is the project's load-bearing invariant: it stays deterministic and reaches no
clock, socket, or scheduler ([First Principles](../../../AGENTS.md#first-principles)).
A netlayer must connect that core to real sockets without dragging `std.Io`,
allocation surprises, or a hidden run loop back across the boundary — and it must
bound the memory an untrusted partner can make a connection hold.

## Decision

**The netlayer is `src/net_adapter/`, outside the core.** The arch gate
([`tools/arch_check.zig`](../../../tools/arch_check.zig)) keeps the five core
layers free of `std.Io` and admits `net_adapter` as a non-core layer that may
import down to `runtime` but is itself imported only by `c_abi` and the public
root. It is the one place `std.Io` enters.

**`Connection` folds the one parser over a type-erased stream.**
[`pumpOver`](../../../src/net_adapter/connection.zig) drives a
`*std.Io.Reader` / `*std.Io.Writer`: it encodes + flushes queued outbound, then
applies one inbound frame via `recvStreamPrefix` ([ADR-0029](ADR-0029-one-parser-stream-framing.md))
and `toss`es its bytes, distinguishing graceful EOF (`closed`) from mid-frame EOF
(`TruncatedFrame`). Decoupling from the socket means the framing core is proven
with `Reader.fixed` / `Writer.fixed`, no socket required.

**`tcp.zig` is the only `std.Io.net`-to-socket site.** It maps a locator's
`host:port` designator to a `std.Io.net.Stream` and welds it to a borrowed peer;
the host passes its chosen `std.Io` (Threaded / Uring / …). Transport name is
`tcp-testing-only` — cleartext, honest naming.

**The C ABI re-exposes blocking endpoint handles.** A host that owns the peer
shuttles whole frames through `pancake_endpoint_tcp_*` (`read_frame ->
feed_owned -> step -> take_outbound -> write_frame`). The C side cannot name a
`std.Io`, so the I/O backend is an *explicit owned handle*: the host creates a
`PancakeTcpNetlayer` (which owns one `std.Io.Threaded`), makes connections and
listeners from it, and frees it after closing them. This is the boring-handle
translation of "pass `Io` in" — no hidden process-global runtime, no lazy
init, an explicit teardown. `pancake_last_error` re-surfaces the concrete
socket cause behind a flat `PANCAKE_ERR_IO`.

**Per-connection inbound memory is bounded by `SessionLimits.max_frame_bytes`.**
A frame whose scanned length crosses the bound is `too_large` (ADR-0029); a full
read buffer that has not yielded a frame is refused before an over-read. Slice 1
sizes the read buffer to `max_frame_bytes` so any admissible frame fits whole —
a documented loopback simplification, not the steady-state production shape.

## Scope (what this defers, by name)

- **Small-buffer + bounded-overflow.** A small fixed read buffer plus a bounded
  owned-accumulation path for frames larger than the buffer, so steady
  per-connection memory stops scaling with `max_frame_bytes`. Out of slice 1
  (loopback, few connections); add it when a many-connection server needs it.
- **Full-duplex backpressure.** A single fiber mid-`writeAll` to a slow reader can
  head-of-line-block. Request/response traffic (handshake, fetch, deliver/resolve)
  is safe on one fiber; concurrent streaming wants split read/write fibers and a
  bounded outbound queue *above* `pump`, not a change to it.
- **Crossed-hellos.** Needs a small adapter registry keyed by
  `(transport, designator)` with the bytewise Public-Identifier tie-break; the
  core already owns only the `crossed_hellos` abort kind.
- **TLS / QUIC / iroh / Tor and any background run loop.** Layer above the same
  `Connection` / `FrameStream` types.

## Alternatives Considered

- **Netlayer inside the core.** Rejected: dragging `std.Io` into the core breaks
  the sync no-I/O invariant and the determinism the conformance harness depends on.
- **A generic comptime `Endpoint` abstraction.** Rejected for slice 1: every
  byte-stream transport already funnels through `std.Io.Reader`/`Writer`; a
  concrete `Connection` over those is simpler and proven without a socket.
- **Unbounded read buffer / grow-to-fit.** Rejected: lets a hostile partner force
  unbounded per-connection memory; the bound is the whole point.
- **Expose `std.Io` across the C ABI.** Rejected: the C host cannot name a Zig
  `Io`; an explicit `PancakeTcpNetlayer` handle that *owns* the backend keeps the
  seam boring (`ptr+len`, return codes) without a hidden global runtime.
- **A process-global lazily-initialized backend.** Rejected: a global
  `std.Io.Threaded` conjured on first use is the hidden runtime this project
  forbids — no teardown, and an init race needing a hand-rolled guard. The owned
  handle is explicit, freeable, and race-free by construction.

## Consequences

- `SessionLimits` gains `max_frame_bytes`; `abort_projection` maps
  `FrameTooLarge` to `resource_exhausted` + close.
- New module `src/net_adapter/` (`connection`, `tcp`, `frame_stream`); `c_abi`
  gains endpoint handles, `last_error`, and bootstrap registration; `pancake.h`
  and `bindings/README.md` track the grown surface.
- Evidence: `Reader.fixed`/`Writer.fixed` framing tests
  ([`test/net_adapter/connection_test.zig`](../../../test/net_adapter/connection_test.zig)),
  the TCP loopback handshake + bootstrap-fetch round-trip
  ([`test/net_adapter/tcp_test.zig`](../../../test/net_adapter/tcp_test.zig)), and
  the C-ABI frame-seam loopback
  ([`test/c_abi/endpoint_loopback_test.zig`](../../../test/c_abi/endpoint_loopback_test.zig)).

## Notes

- [ADR-0029](ADR-0029-one-parser-stream-framing.md) owns the framing this folds
  over; [ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md) owns the
  handshake/bootstrap-fetch halves the connection drives without special-casing;
  [ADR-0025](ADR-0025-session-table-cap-policy.md) owns the `resource_exhausted`
  posture `FrameTooLarge` joins.
