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

> **Amendment (2026-06-12):** this resident was renamed `memory` → `inproc`
> (transport symbol, `net.inproc`, `src/net/transport/inproc.zig`, and the
> `pancake_inproc_*` C ABI family). "memory" named the substrate, not the
> behavior, and read as "about memory" in a systems library; `inproc` names what
> it is — an in-process transport — and keeps the C family prefix equal to the
> `.inproc` designator a consumer writes. The decision below is unchanged; read
> `memory` as `inproc` throughout.

## Context

The netlayer contract (ADR-0043) had exactly one resident, tcp. One resident
cannot prove a contract is general — it can only prove it fits that one
transport. The contract could have been accidentally socket-shaped: a
`Connection` borrows a `*std.Io.Reader` / `*std.Io.Writer` pair and a close
handle, and tcp is the only thing that had ever produced them. Until a second,
genuinely different transport drives the same path, "bring your own netlayer" is
a claim, not a demonstrated property. The existing `x-loopback` test transport
does not settle this: it rides tcp under the hood, so it proves dispatch, not
that a non-socket transport fits.

This engages the First Principle that netlayers are contracts the core
dispatches against, never privileged built-ins, and that the portable core stays
I/O-free while adapters own transports.

## Decision

`net.inproc` is a second real resident with no sockets and no file descriptors.
A `Network` is a switchboard: a listener binds to a designator, a dialer names
that designator, and the two are wired by a `Duplex` of two in-process byte
pipes — one per direction. Each pipe is a thread-safe FIFO that blocks the
reader until the writer produces bytes or closes (clean EOF), exposed through a
`std.Io.Reader` / `std.Io.Writer` pair whose vtables mirror `net.Stream`'s. The
driver dials it with `connectVia` and hosts it with `acceptVia` — the same
transport-neutral path tcp uses — completing the same verified keyed
`op:start-session` handshake, and a full conversation (handshake, bootstrap
fetch, deliver, fulfilled reply) round-trips entirely in process.

The architectural result is the point: the contract generalized with **no edit
to the driver or the core**. The in-process transport needed only an in-process
stream and a switchboard, both pure `net` concerns. Two real residents — a
socket transport and a non-socket one — are the shape that extends to a third
(the QUIC/iroh resident) and to a caller's own transport.

Blocking uses the io-aware `std.Io.Mutex` / `std.Io.Condition`, so a handshake
half parks under whatever `std.Io` backs it (a threaded backend blocks the
thread; a fiber backend yields). The two vtable `close` callbacks that run
without an `io` in hand — the transport-handle close and the listener close —
use a non-blocking spinlock over a refcount and a map removal only, never to
wait.

## Scope (what this does not decide)

- **This is a testing and mocking transport, not a production one.** Its pipes
  are unbounded (a mock has a cooperative partner), and it blocks a thread per
  parked read, so it does not carry high-fan-out production load. The production
  second resident — a secure QUIC/iroh transport — is still open (ladder rung
  5). This ADR validates the contract; it does not fill the production slot.
- **No new contract surface.** The contract (ADR-0043) is unchanged. This
  resident is added by registering it, which is the property under test.

## Alternatives Considered

- **Treat `x-loopback` as the second resident.** Rejected: it rides tcp, so it
  proves only that the driver dispatches on an arbitrary symbol, not that a
  non-socket transport fits the `Connection` contract.
- **A frame-oriented memory endpoint (like the foundation `MemoryEndpoint`).**
  Rejected for this purpose: the contract is a byte stream, and iroh — the real
  next resident — is also a byte stream (QUIC streams), so a byte-stream
  in-process resident validates the shape iroh will actually use. A frame
  transport would test a contract pancake does not have.
- **Generalize the contract to admit frame transports now.** Rejected as
  premature: no shipped or planned transport needs it (iroh is stream-shaped),
  and adding a second contract shape before a consumer needs it is the kind of
  speculative surface the project avoids.

## Consequences

`src/net/transport/inproc.zig` is new and `net` re-exports it as `inproc`.
`test/driver/inproc_netlayer_test.zig` drives a full round-trip and a
fail-closed dial through the contract. The ladder's rung 5 and the README record
that the contract now has two real residents, with the production secure
resident still open. No driver, core, or contract file changed to add the
resident — the proof the ADR exists to give.

## Notes

Builds on ADR-0043 (the netlayer contract) and ADR-0030 (the connection and
per-connection memory posture). The QUIC/iroh resident in the roadmap slots in
the same way this one did.
