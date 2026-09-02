---
id: ADR-0114
status: accepted
date: 2026-08-12
tags: [lifecycle, driver, c-abi, bindings, transports]
decision: "An owning Host, Runtime, or Session closes under an explicit pending-work policy: cancel stops admitted work, while finish seals admission and drives already-admitted work within an explicit grace budget before closing. Expiry escalates to cancel. Listener and transport close remain single-purpose levers, implicit cleanup always cancels, and CapTP keeps its negotiating | open | closed lifecycle."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0114 Pending-work close policy

## Context

Closing an owning binding Host currently cancels its asynchronous dials, action
drains, sessions, and vows. That gives resource cleanup a completion barrier,
but it gives an application no way to stop admitting work and let operations it
already started settle first. Server fronts also differ in whether close waits
for sessions already returned to the application.

A CapTP session is not a finite request. It may host capabilities indefinitely,
and a vow may never settle. CapTP also has no draining state: `op:abort` is
terminal, as ADR-0083 records. A finish option therefore needs an explicit
budget and must live above the protocol state machine.

## Decision

The application-facing owners use one terminal `close` operation with a
pending-work policy:

- `cancel` seals admission, cancels owner-managed tasks, breaks outstanding
  operations, closes child sessions, and waits until their execution state can
  be released.
- `finish` seals admission, continues driving work admitted before the barrier,
  and closes child sessions after that work settles and its output flushes. The
  caller supplies a finite grace budget or explicitly chooses an unbounded one.
  Expiry escalates to `cancel`; close still reaches its release barrier, then
  reports the timeout.

The state transition is monotonic. A repeated finish observes the existing
barrier. Cancel may escalate an in-progress finish, while finish never weakens a
cancel already in progress. Cancelling one waiter does not cancel the shared
close operation.

Pending work includes transport opens, Host action drains, locally initiated
vows, and deferred hosted answers that were admitted before close. Live sessions
and published capabilities are resources, not pending operations. During a
finish, existing sessions remain protocol-responsive so admitted operations can
settle. A new application operation or a new deferred answer is refused and
cannot extend the grace period.

The policy sits at the layer that owns the work:

| Surface | Close contract |
| --- | --- |
| `driver_core.Host` | Owns the admission barrier and the inventory of pending CapTP work. It does not read a clock or perform I/O. |
| `driver.HostRuntime` and `libglowcap_driver` | Supply monotonic time, drive existing wires, flush terminal output, and interrupt transports when the core requests cancellation. |
| `libglowcap_host` | Exposes begin/escalate and readiness to an embedding that owns the clock and byte channels. Release remains memory ownership, not a policy choice. |
| Zig and language-binding Host, Runtime, and owning Session fronts | Present one idiomatic close operation and wait for its barrier. Resource-management protocols use cancel. |
| Server/listener fronts | Stop admission and retire unclaimed accepts. Sessions already returned to an application remain application-owned; a server close does not gain a misleading policy knob. |
| Transport connections, listeners, endpoints, and provider runtimes | Keep one interruptible close/shutdown lever and one release boundary. They do not decide whether CapTP work should finish. |

The language syntax is idiomatic rather than mechanically identical. Zig and
Rust use a tagged policy type. TypeScript uses an options object. Python uses a
keyword argument and enum. Racket uses a keyword argument and symbols. Each
surface uses the terms `pending`, `cancel`, and `finish` for the same decision.

## Scope (what this does not decide)

This policy does not create a wire-level draining state or a second CapTP
shutdown verb. It does not claim that cancelling one local await cancels remote
execution; an operation-specific cancellation API may only make that claim when
the protocol can carry it. It also does not transfer ownership of an accepted
session back to the server that yielded it.

The policy governs owning Host, Runtime, and Session fronts. It does not govern
listener retirement or raw transport release, whose narrower ownership
contracts remain unchanged.

## Alternatives Considered

- **`graceful: bool`**: rejected because it does not say which work counts or
  what happens when that work never settles.
- **Separate `close` and `close_async` or `shutdown` methods**: rejected because
  the distinction is policy, not sync versus async naming. One operation owns
  the barrier.
- **Put finish/cancel on every transport close**: rejected because a transport
  cannot see CapTP vows or hosted answers. The owner finishes protocol work,
  then the transport performs interruption and release.
- **Wait for every live session to end naturally**: rejected because sessions
  are open-ended resources, not finite work, and accepted sessions may belong
  to another application owner.

## Consequences

The Host core needs a close state and a quiescence query that count one
authoritative pending-work inventory. Driver and byte-fed embeddings must keep
I/O alive during finish and provide a reliable cancellation edge at expiry.
Bindings must retain one close task so repeated calls share the same barrier.

Finalizers, destructors, async-disposal defaults, and error unwinds cancel. They
cannot choose an unbounded finish because implicit cleanup must not hang. An
application that wants pending work to settle asks for finish explicitly.

## Evidence and gate

Core and Runtime scenarios cover finish quiescence, grace expiry,
finish-to-cancel escalation, callback-time admission, and terminal output
ordering. Binding dogfoods cover cancel and finish barriers, repeated close,
and callback-time close without binding-owned policy. Server and listener tests
pin the separate contract: stop admission while preserving yielded sessions.
`zig build check` remains the repository gate.
