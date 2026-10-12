---
id: ADR-0047
status: accepted
date: 2026-06-11
tags: [net, netlayer, testing, architecture]
decision: "Ship an in-process netlayer (net.inproc) as a second real resident behind the ADR-0043 contract: a designator-keyed switchboard wires a dialer and a listener through two in-process byte pipes exposed as the same std.Io.Reader/Writer pair tcp produces, so the driver dials and hosts it through the identical connectVia/acceptVia path with the verified keyed handshake and no driver or core edit. It exists to validate that the netlayer contract is transport-general rather than socket-shaped, and to give tests a full OCapN conversation in one process with no sockets or file descriptors."
supersedes: []
superseded_by: []
---

# ADR-0047 In-process netlayer

> **Amendment (2026-06-12):** this resident was renamed `memory` to `inproc`
> (transport symbol, `net.inproc`, `src/net/transport/inproc.zig`, and the
> `glowcap_inproc_*` C ABI family). "memory" named the substrate, not the
> behavior. `inproc` names an in-process transport and keeps the C family prefix
> equal to the `.inproc` designator a consumer writes. The decision below is
> unchanged. Read `memory` as `inproc` throughout.

## Context

The netlayer contract (ADR-0043) had one resident, tcp, which can only prove the
contract fits that transport. The contract could be socket-shaped: a
`Connection` borrows a `*std.Io.Reader` / `*std.Io.Writer` pair and a close
handle, and only tcp had produced them. "Bring your own netlayer" needs a
second, different transport driving the same path. The `x-loopback` test
transport rides tcp, so it proves dispatch, not that a non-socket transport
fits.

## Decision

`net.inproc` is a second real resident with no sockets and no file descriptors.
A `Network` is a switchboard: a listener binds to a designator, a dialer names
that designator, and the two are wired by a `Duplex` of two in-process byte
pipes, one per direction. Each pipe is a thread-safe FIFO that blocks the
reader until the writer produces bytes or closes (clean EOF), exposed through a
`std.Io.Reader` / `std.Io.Writer` pair whose vtables mirror `net.Stream`'s. The
driver dials it with `connectVia` and hosts it with `acceptVia`, the same
transport-neutral path tcp uses, completing the same verified keyed
`op:start-session` handshake, and a full conversation (handshake, bootstrap
fetch, deliver, fulfilled reply) round-trips entirely in process.

The contract generalized with no edit to the driver or the core. The
in-process transport needed only an in-process stream and a switchboard, both
`net` concerns. A socket transport and a non-socket one extend to a third (the
QUIC/iroh resident) and to a caller's own transport.

Blocking uses the io-aware `std.Io.Mutex` / `std.Io.Condition`, so a handshake
half parks under whatever `std.Io` backs it (a threaded backend blocks the
thread, a fiber backend yields). The two vtable `close` callbacks that run
without an `io` in hand (the transport-handle close and the listener close)
use a non-blocking spinlock over a refcount and a map removal only, and never
wait.

## Scope (what this does not decide)

- **This is a testing and mocking transport.** Its pipes are unbounded (a mock
  has a cooperative partner), and it blocks a thread per parked read, so it does
  not carry high-fan-out production load. The production second resident (a
  secure QUIC/iroh transport) is open (ladder step 5).
- **No new contract surface.** The resident is added by registering it, which
  is the property under test.

## Alternatives Considered

- **Treat `x-loopback` as the second resident.** Rejected: it rides tcp, so it
  proves only that the driver dispatches on an arbitrary symbol, not that a
  non-socket transport fits the `Connection` contract.
- **A frame-oriented memory endpoint (like the foundation `MemoryEndpoint`).**
  Rejected: the contract is a byte stream, and iroh (the next resident) is also a
  byte stream (QUIC streams), so a byte-stream in-process resident validates the
  shape iroh uses.
- **Generalize the contract to admit frame transports now.** Rejected: no
  shipped or planned transport needs it (iroh is stream-shaped).

## Consequences

`src/net/transport/inproc.zig` is new and `net` re-exports it as `inproc`.
`test/driver/inproc_netlayer_test.zig` drives a full round-trip and a
fail-closed dial through the contract. The ladder's step 5 and the README record
that the contract has two real residents, with the production secure resident
open. No driver, core, or contract file changed to add the resident.

## Notes

Builds on ADR-0043 (the netlayer contract) and ADR-0030 (the connection and
per-connection memory posture). The QUIC/iroh resident in the roadmap slots in
the same way this one did.
