---
id: ADR-0043
status: accepted
date: 2026-06-10
tags: [net, driver, transport, architecture]
decision: "A netlayer is a runtime resident vtable the driver dispatches against by transport symbol, over a transport-generic Connection; tcp is its first resident."
supersedes: []
superseded_by: [ADR-0062]
---

# ADR-0043 Netlayer contract: runtime residents over a transport-generic Connection

> Superseded by [ADR-0062](ADR-0062-one-connect-over-a-netlayer-slice.md): the
> runtime-vtable transport type is renamed `Contract` -> `Netlayer` and the
> `Registry` struct is replaced by a bare `[]const Netlayer` slice. The boundary
> this ADR drew: a transport is a runtime vtable the driver dispatches by
> symbol, never a privileged built-in: is retained.

## Context

Before this decision tcp was the only transport, and it was privileged in two
ways the vision's "Pluggable By Contract" principle forbids. First,
`net.Connection` welded `std.Io.net.Stream.Reader`/`Writer` into its fields and
reached into `reader.stream.socket.handle` and `reader.stream.close`, so only a
real TCP socket could drive the engine seam: even though the framing core
`pumpOver` was already generic over `*std.Io.Reader`/`*std.Io.Writer`. Second,
the driver named the literal `"tcp"` at its dial/host constructors, so a locator
carrying any other transport had nowhere to go. The OCapN locator carries its
transport as a runtime symbol parsed from a URI or read off an inbound
`op:start-session`, so dispatch on it must be runtime; a comptime transport
parameter would re-privilege whichever transports were known at build time. This
sits on the architecture's core/adapter boundary and on the "no hidden runtime /
explicit ownership" principle: the netlayer set is a value the host owns, not a
process global.

## Decision

A netlayer is a runtime vtable, `net.netlayer.Contract`, that turns a locator
into a live `Connection` (`dial`) and binds a `Listener` (`listen`); the host
holds a `net.netlayer.Registry` and the driver's `connectVia` / `acceptVia`
dispatch on the locator's transport symbol against it, failing closed with
`error.UnknownTransport` rather than defaulting to any transport. `Connection`
becomes transport-generic: it stores `*std.Io.Reader` / `*std.Io.Writer` plus a
type-erased `TransportHandle` that closes the underlying stream and reports an
optional socket descriptor, so any transport that yields the std.Io interfaces
drives the one framing core unchanged. Because `Connection` borrows the
interface pointers and is moved by value, the producing transport must keep its
concrete reader/writer at a stable address for the connection's life,
`std.Io.Reader`'s vtable recovers the concrete reader from `&interface` by field
offset: so tcp pins a small per-connection stream wrapper on the peer's
allocator and frees it through the handle. tcp is the contract's first resident
(`tcp.Resident`, `tcp.netlayer`), reached only through the vtable under the
symbol `tcp`. The tcp-named conveniences (`connectTcp`, `acceptTcp`, `dial`)
stay as they are: they pick tcp explicitly and honestly, which is
not the privilege the vision forbids: that privilege lived in the _generic_
path, which now dispatches. Owned by `src/net/netlayer.zig`,
`src/net/connection.zig`, `src/net/transport/tcp.zig`, and `src/driver/mod.zig`.

## Scope (what this does not decide)

The completion `Loop` is deliberately _outside_ the contract. It multiplexes raw
kernel fds through an io_uring/kqueue backend and never builds a `Connection`,
so it cannot drive a userspace UDP transport; it is a tcp-and-fd affordance
beside the contract, not a capability every netlayer must offer. ADR-0051 adds
outbound dialing to that fd loop without changing this boundary: a userspace
transport still scales by running many `Connection` pumps on its own loop. No
second transport is implemented here: a QUIC/iroh resident is not built, and
confidentiality stays unimplemented (tcp is still cleartext). The contract's
error sets are coarse on purpose (`InvalidAddress` / `ConnectionLost` /
`BindFailed`); a transport's private cause is not surfaced through them.

## Alternatives Considered

- **Comptime/generic netlayer parameter**: zero indirection. Rejected because
  the transport symbol is a runtime value, so this cannot select a transport
  from a URI or an inbound handshake without re-privileging build-time
  transports.
- **One fat vtable that includes the completion Loop**: a tidier "one contract"
  story. Rejected because a userspace transport cannot implement OS-completion
  over fds; the slot would be a lie or would drag the transport's own loop into
  the core.
- **Keep the stream inline in a type-erased buffer**: avoids the per-connection
  wrapper allocation. Rejected because a moved `Connection` would leave the
  interface pointers (recovered by field offset) dangling: the wrapper must be
  pinned outside the movable connection.

## Consequences

- Adding a transport is new files plus one registration call: no edit to the
  core (foundation/model/codec/session/engine), to `src/driver`, or to
  `connection.zig` / `completion/loop.zig` / `transport/tcp.zig`.
  `test/driver/pluggability_test.zig` proves this now: a transport defined in
  test code under the symbol `x-loopback` dials and hosts through `connectVia` /
  `acceptVia` with the verified handshake, with no core or driver change.
- One named per-connection allocation on the blocking path: tcp pins its stream
  wrapper on the peer's allocator (recorded in the memory rule's load-bearing
  list). The completion `Loop` path is untouched: peer-scaling memory is
  unchanged (0.65 GiB warmed at 500k).
- `Connection.socketHandle()` now returns `?Handle`; `driver.stepReadable` polls
  only when a pollable fd exists and otherwise falls through to a blocking step.
- `net.netlayer.Listener` is now the contract's pluggable listener; the concrete
  bound TCP socket is `net.tcp.Listener`.
- Live Goblins interop passes both directions over the refactored wire path.

## Forward compatibility

A QUIC/iroh resident slots in as `src/net/quic.zig` implementing
`Netlayer.VTable`. `dial` opens a QUIC stream and builds a `Connection` over
its reader/writer with a `TransportHandle` whose `socketHandle` returns null;
`transport_name = "quic"`; the node id is the dialable designator. The host
registers it; the driver already dispatches `quic` by symbol. The
key-as-designator identity such a transport carries is the seam `ocapn://` URI
dialing and durable identity wait on (see [the roadmap](../../roadmap.md)).

## Notes

Builds on ADR-0030 (bring-your-own-reader/writer transport seam), ADR-0041
(bounded inbound spill), and ADR-0042 (outbound high-water backpressure).
