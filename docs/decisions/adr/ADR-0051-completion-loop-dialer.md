---
id: ADR-0051
status: accepted
date: 2026-06-11
tags: [net, completion-loop, dialer, scaling, driver]
decision: "The completion loop supports outbound TCP dialing through a backend `submitConnect` operation and one shared connection lifecycle for accepted and dialed sockets. The driver exposes the client fan-out surface above the loop. The core protocol layers and the runtime netlayer contract do not change."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0152]
---

# ADR-0051 Completion-loop dialer

## Context

The completion loop already owns the high-fan-out accepted-socket path: one
portable `completion.Loop` over an io_uring or kqueue backend accepts, reads,
writes, applies backpressure, and runs application hooks without a blocking
fiber per connection. OCapN is symmetric: a mesh node that hosts many peers also
initiates many sessions, especially once handoff and the iroh netlayer make
client-side fan-out common.

The netlayer contract (ADR-0043) is the transport-general path: `Netlayer.dial`
returns a `Connection` over a transport-provided reader/writer. The completion
loop multiplexes raw kernel fds directly and drives `engine.Peer` without
constructing a `Connection`, so it keeps per-connection read buffers, pending
writes, parked reads, and teardown state in one slot table. Dial support there
is the fd/TCP completion runtime gaining its outbound half, not a new
`Netlayer` requirement.

## Decision

- **Backends gain `submitConnect`.** The completion-backend contract adds an
  outbound socket operation beside accept/recv/send/close. Linux implements it
  with io_uring connect. Darwin starts a nonblocking connect and completes it
  through kqueue write readiness plus `SO_ERROR`.
- **The portable loop owns one connection lifecycle.** Accepted and dialed
  sockets share the same `Conn` state: read buffer, spill, outbound queue, write
  offset, parked reads, in-flight operation count, application context, and
  teardown. Dialing reserves a slot, creates the peer, submits connect, then
  arms reads and drives the opening sends after the connect completes.
- **The driver owns the client fan-out surface.** A driver-level dialer wraps
  the loop for applications, the same way `LoopHost` wraps accepted connections.
  It creates one negotiating peer per outbound connection, signs the dialer half
  of `op:start-session`, and routes events through driver-owned per-connection
  context. The no-I/O core does not learn about sockets, loops, or dialing.
- **The netlayer contract does not change.** `Netlayer` stays the
  transport-general reader/writer contract. A userspace transport such as iroh
  still plugs in as a resident behind ADR-0043. It is not required to implement
  the fd completion loop.

## Consequences

- The completion loop serves and initiates many TCP sessions from the same
  runtime shape. The shared read-buffer ring and live 500k socket measurement
  are separate density and measurement work.
- Backend implementations stay platform-local. `completion/loop.zig` knows about
  connection state, not Linux or Darwin syscalls.
- Accepted-side `LoopHost` behavior is unchanged, and the server tests pass
  unchanged.

## Scope

This does not build a QUIC/iroh transport, a Windows IOCP backend, a shared
provided-buffer ring, or a wall-clock performance gate. Those remain separate
roadmap items.
