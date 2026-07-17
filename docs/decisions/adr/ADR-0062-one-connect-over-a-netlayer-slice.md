---
id: ADR-0062
status: accepted
date: 2026-06-15
tags: [net, driver, transport, c-abi, public-surface, vocabulary]
decision: "One dialer per layer, and it takes a locator, never a host and port. In Zig the transport set is a bare `[]const net.netlayer.Netlayer` the driver dials and hosts against, not a `Registry` struct, and the runtime-vtable transport type is renamed `Contract` -> `Netlayer`; a free `net.netlayer.resolve(netlayers, symbol)` replaces `Registry.resolve`. A transport builds its own locator with no ritual: `tcp.at(designator)` builds a `tcp` locator from a `host:port` string the caller already holds, owning the empty-hints wire form so `.emptyFalse()` never reaches a call site and the signed handshake bytes are unchanged. The dial/host functions (`driver.connect`, `connectVia`, `connectUri`, `connectUriOwned`, `acceptVia`, `listen`) take the slice instead of the `Registry`; the ownership tiers (owning `Session`/`Server`, borrowing buffer-explicit `connectVia`/`acceptVia`/`connectTcp`/`acceptTcp`) are kept, because collapsing them would delete the explicit-allocation surface the project requires. In the bindings the one dialer is `connect(locator)` over an `ocapn://` URI with `tcp_locator(host, port)` as the only literal-address helper; the per-transport dial twins are gone. The C ABI gets the same front door per transport: `libpancake_net_transport_tcp` grows an owning `PancakeTcpSession` (`pancake_tcp_session_connect`/`_fetch`/`_call`/`_release`) (the C spelling of `driver.Session`) that embeds the actor runtime and pairs with a runtime host, with the bare sans-io peer kept for a host that owns its own loop."
supersedes: [ADR-0043]
superseded_by: []
---

# ADR-0062 The connection front door: one `connect`, Zig and C

## Context

[ADR-0043](ADR-0043-netlayer-contract.md) made a transport a runtime vtable,
`net.netlayer.Contract`, that the driver dispatches against by transport symbol,
held in a `net.netlayer.Registry` struct. This ADR settles the dialing front
door across all three layers: the Zig driver, the language bindings, and the C
ABI: on one principle: **each layer dials a peer through exactly one `connect`,
and `connect` takes a locator, never a host and port.** A dial that takes
`host, port` is a boundary claim that the caller chooses the transport, when the
locator already names the transport and the registry already dispatches on it;
multiple ways to dial one peer is exactly the surface the project's values
forbid.

Two construction frictions stand in the way of that front door. The bindings had
accreted a parallel dial per transport (`connect(host, port)`, `connect_iroh`,
`connect_iroh_uri`, plus a fourth dispatching `connect_uri`), leaking the
transport up into the function name. And a native Zig client reaching one TCP
peer still wrapped a `Contract` in a `Registry{ .entries = &.{…} }`,
hand-formatted a `host:port` into a stack buffer, and wrote a
`model.PeerLocator{ … .hints =
.emptyFalse() }` literal: the wrapper and the
`.emptyFalse()` incantation pure ceremony, with most examples hand-rolling the
locator rather than finding the helper behind the wrapper.

This sits on two [First Principles](../../../AGENTS.md#first-principles),
**boring public surface** and **make the correct path the easy path**: and on
the value that _names and structure are architecture_. The fix removes concepts
(the per-transport dial twins, the `Registry` struct, the ritual hint spelling);
it does not add a convenience verb, which would grow surface.

## Decision

**The transport set is a bare `[]const net.netlayer.Netlayer`, and a transport
builds its own locator with no ritual.**

- The runtime-vtable transport type is renamed `net.netlayer.Contract` ->
  `net.netlayer.Netlayer`. The name now says what the value is.
- The `net.netlayer.Registry` struct is **removed**. The transport set is a bare
  `[]const Netlayer`; a one-transport client passes `&.{ tcp.netlayer() }` and a
  multi-transport client passes `&.{ tcp.netlayer(), iroh.netlayer() }`: the
  same call, one element longer. A free
  `net.netlayer.resolve(netlayers, symbol)` replaces the old `Registry.resolve`
  method, failing closed (returning null, so the driver raises
  `Error.UnknownTransport`) when no netlayer hosts the symbol.
- `tcp.at(designator)` builds a `tcp` locator from a `host:port` string the
  caller already holds: what `argv` hands a client, or a `Server`'s
  `localDesignator`. The locator constructor owns the empty-hints wire form
  (`.emptyFalse()`, the spelling Goblins signs a tcp locator with), so a caller
  never types `.hints` and the signed `op:start-session` bytes are byte-for-byte
  unchanged. The typed `tcp.locator(buf, address)` stays for a caller holding an
  `IpAddress`; `inproc.locator(designator)` already had this shape.
- The dial and host functions take the slice in place of the `Registry`:
  `driver.connect` and `connectUriOwned` (owning), `connectVia` and `connectUri`
  (borrowing), and the resolve inside them. `acceptVia` and `listen` are
  unchanged in shape (they take a bound listener or one netlayer).
- **The ownership tiers are kept.** The owning `Session`/`Server` (one call,
  owned buffers; CapTP partner type, ADR-0079) and the borrowing buffer-explicit
  `connectVia`/`acceptVia` and tcp-named `connectTcp`/`acceptTcp` (caller owns
  the peer and both buffers, every allocation at the call site) are two
  genuinely different ownership contracts, not redundant verbs: the
  `connect_explicit_buffers` example exists to show the borrowing tier.
  Collapsing them would delete the explicit-allocation surface the project's
  values require, which is the opposite of the goal. ADR-0043's judgment that an
  explicit tcp-picking convenience is honest, not the forbidden privilege,
  stands.
- A transport's `std.Io` (or other live state) still lives in its `Resident`,
  reached as `tcp.netlayer()` / `iroh.netlayer()`. A `std.Io` is a 16-byte fat
  pointer and the vtable `ctx` is one pointer, so a stateless transport cannot
  carry its `io` in the vtable value; the `Resident` is its honest home, the
  same shape for every transport.
- In the four bindings the one dialer is `connect(locator)`, taking an
  `ocapn://` URI string and dispatching on its transport.
  `tcp_locator(host, port)` is the one literal-address helper: it builds a
  `tcp` locator rather than dialing, so there is no second dial. `reachability`
  is a trailing argument an `iroh` locator requires and a `tcp` locator ignores
  (the posture has no default. ADR-0055). The per-transport dial twins
  (`connect(host, port)`, `connect_iroh`, `connect_iroh_uri`) are removed; an
  iroh peer is dialed through the same `connect` on the `ocapn://<nodeid>.iroh`
  URI a `listen_iroh` endpoint hands out.

Target front-door call site, nothing hidden and no ritual:

```zig
var tcp_resident = pancake.net.tcp.Resident{ .io = io };
var session = try driver.connect(&.{tcp_resident.netlayer()}, allocator, pancake.net.tcp.at(designator), .ephemeral, .{});
defer session.close();
const greeter = try session.fetch("greeter");
const reply = try session.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "world" }} }, arena);
```

### The C front door: an owning `PancakeTcpSession`

The C ABI reads the same as the Zig `Session`. `libpancake_net_transport_tcp`
grows an owning `PancakeTcpSession`: the C spelling of `driver.Session`, for
the blocking TCP path:

- `pancake_tcp_session_connect(netlayer, host, port, codec, max_frame_bytes, …)`
  dials over the netlayer's I/O backend and completes the ephemeral keyed
  `op:start-session` handshake before returning, so the handle rides an open
  session.
- `pancake_tcp_session_fetch(session, name) -> PancakeReference` runs a
  bootstrap fetch, pumping the socket until the answer settles.
- `pancake_tcp_session_call(session, target, verb, args) -> PancakeSettled`
  delivers and pumps until the answer settles, into a session-owned arena freed
  by `pancake_tcp_settled_release`.
- `pancake_tcp_session_release(session)` tears down the peer, the stream, and
  the buffers it owns.

It owns a socket, so it lives in the transport archive, never in sans-io
`libpancake_ocapn`. An owning session is a driver-level concept, so the archive
embeds `driver` (and transitively `actors`/`engine`): a deliberate trade,
correctness over a leaner archive, since reusing the tested `driver.Session`
pump gives the C session the exact handshake, fetch, and resolver-callback
settlement the Zig surface has. It is a _client_ that pairs with a runtime host
(a `driver.Server`/`acceptVia` host or a Goblins vat), because a v1.0 bootstrap
`fetch`/`call` settles through a resolver capability the actor runtime answers.
The bare sans-io `PancakePeer` stays for a host that owns its own loop and
drives raw frames.

The session reuses `pancake_ocapn.h`'s value vocabulary by _layout_: the same
way the transports reuse `PancakeFrame` (ADR-0059): so `PancakeReference` and
`PancakeArgument` live in the shared leaf `c_abi_shared`, re-exported from the
ocapn root so `pancake_ocapn.h` reflects identically. `PancakeSettled`, the
owning session's settled-outcome projection, lives with its only producer in
`pancake_net_transport_tcp.h`, composing the shared `PancakeArgument` by layout
and promoting to the shared leaf the day a second transport's owning session
mints one.

## Scope (what this does not decide)

- **No keyed identity yet.** The C session's first cut dials ephemeral; a
  keyed-secret arm (the C twin of `.keyed`) and an owning accept-side session
  are later, symmetric additions.
- The completion `Loop` stays outside the netlayer contract (ADR-0043's
  boundary). No codec, session, or engine change follows: this is confined to
  `net/netlayer.zig`, the three transports, `src/driver`, the bindings' dial
  surface, the `libpancake_net_transport_tcp` owning session, and the call sites
  that dial.

## Consequences

- `net.netlayer.Contract` becomes `Netlayer`; `net.netlayer.Registry` is gone.
  Every dial/host site in the driver, the transports, the tests, the conformance
  drivers, and the examples updates from `Registry{ .entries = &x }` to the bare
  `&x` slice and from the hand-rolled locator literal to `tcp.at(...)`.
- The four bindings each lose their per-transport dial twins and gain one
  `tcp_locator` constructor; an iroh peer dials through the same `connect` on
  its `ocapn://<nodeid>.iroh` URI. `include/pancake_net_transport_tcp.h` gains
  the `pancake_tcp_session_*` family and the `PancakeSettled` struct; the moved
  value structs re-export from the ocapn root so `pancake_ocapn.h` reflects
  identically. The owning session is proven by `test/c_abi/tcp_session_test.zig`
  against a `driver.Server` host.
- Signature verification is unchanged: the empty-hints wire form moved from the
  call site into `tcp.at`, which sets the identical `.emptyFalse()`, so the
  signed `op:start-session` bytes are byte-for-byte the same. `zig build check`
  (driver loopback, oracle), `zig build examples`, the C `tcp_session` test, and
  the live `goblins-interop` / `bindings` siblings hold this.

## Notes

- Supersedes [ADR-0043](ADR-0043-netlayer-contract.md) for the `Contract` ->
  `Netlayer` rename and the `Registry` struct -> bare-slice change, keeping its
  boundary: a transport is a runtime vtable the driver dispatches by symbol,
  never a privileged built-in.
- The C owning session embeds the runtime and shares the value vocabulary by
  layout under [ADR-0059](ADR-0059-composable-c-abi-archives.md); the bare
  sans-io peer surface and the frame-boundary functions are unchanged for a host
  that owns its own loop.
