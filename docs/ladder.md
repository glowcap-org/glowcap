# pancake: The Ladder

This is the dependency-ordered route toward 1.0, and the record of where each
rung stands. [`vision.md`](vision.md) says where pancake is going. This file
says what has to be true, and in what order, for that destination to be reached
honestly. It also says which rungs the gates already prove. When a rung's
standing changes, this file changes in the same diff. It is a living-state
surface under the [doc-drift rule](../.agents/rules/doc-drift.md).

The ordering is an argument, not a wish list. Each rung exists because the rung
above it would be dishonest without it: conformance claims mean nothing if a
performance contract has not yet been written down to defend, an application
surface built before conformance bakes in protocol bugs as API, and a second
netlayer before a first consumer optimizes a boundary nobody has pushed on.

## Standing discipline: structure as enforcement

This is the floor every rung stands on, not a rung itself. The layer DAG is not
a convention. Each `src/` layer is an internal build.zig module with a one-way
import table, so codec-neutrality of the session, codec isolation, and the
core/adapters split are compile errors to violate (ADR-0040). Below the codec
layer, each sibling wire codec is its own module, so Syrup and Cap'n Proto
cannot import each other either (ADR-0048). The DAG is one declaration, the
`layer_table` in build.zig, and the arch gate checks it against the tree. A
granted edge that no file imports fails, and so do the content bans a module graph
cannot express: no `std.Io` or threading in the core, and no platform syscall
namespaces in portable code. `zig build check` runs that gate. A claim about
layering in any doc defers to the `build.zig` table. The `src/` layout is
settled; keeping it settled is part of this standing discipline, never a
session's mission.

## Rung 1: Conformance For The Portable Sync Core

This rung is held by gates, and its breadth is still growing.

OCapN behavior, Spritely Goblins fixtures, and Zig-local protocol scenarios are
the conformance authority. pancake is the implementation, and no other
implementation is the oracle for its semantics. The standing rule is that a
semantic claim without a scenario or fixture is a wish. Today the proof is the
oracle corpus (`zig build oracle-check`, with `fixture-gen-check` holding the
corpus against the upstream Syrup encoder), the cross-codec parity traces, the
live Goblins conversations in both directions (`goblins-interop`,
`goblins-handoff`), and the upstream OCapN suite (`ocapn-conformance`). What
keeps this rung open is breadth, not machinery. When a change touches an edge
the spec names but no scenario pins yet, that change adds the test. The protocol
machinery the beachheads stand on (promise pipelining, three-party handoffs,
sturdyref enlivenment, and attenuated delegation) carries the most conformance
weight, and Goblins-canonical extensions get flagged wherever they appear.

## Rung 2: The Performance Contract, In Numbers

The per-session footprint budget is held by gates. Live-socket measurement is
opt-in Phase 2 of `bench-peer-scaling` (`--live`); it reports measured RSS and
ns/turn at stepped N rather than only extrapolating the in-process `served` row.

The 500k-connection destination is a budget, not a claim, and a budget is only
real once a gate defends it. Two halves of the wire-and-session cost are
mechanical checks. The wire-path allocation floor is exact: a steady-state
`op:deliver` to a live export costs exactly one heap allocation, the owned-frame
copy the event model requires, pinned by `test/engine/alloc_budget_test.zig`.
The per-session footprint is bounded: `engine.Peer` carries a `comptime` ceiling
on its own struct size, so a session's inline state staying under one kilobyte
is a compile error to break, and `test/engine/footprint_budget_test.zig` holds
the warmed total (struct plus session heap) at or under 2 KiB per session.
2 KiB times 500_000 sessions is under 1 GiB of protocol-core state.
`zig build bench-peer-scaling` reports the live measured numbers and
extrapolates to 500k; `zig build check` runs it in `--smoke` mode and runs both
budget gates.

The completion loop wraps each `Peer` in one `Conn` slot, and that wrapper is
the unit the loop allocates `max_conns` of, so it carries a ceiling of its own.
A `Conn`'s bookkeeping beyond the `Peer` it embeds — the slot state, the
outbound queue's two buffer headers, the spill header, the intrusive free or
starved link, and the in-flight and app-context words — measures 112 bytes on
every backend, and a `comptime` assertion in `net/completion/loop.zig` holds
`@sizeOf(Conn) - @sizeOf(engine.Peer)` at or under **120 bytes**
(`conn_slot_overhead_bytes`, one word of headroom for cross-target padding). The
ceiling isolates the wrapper from the `Peer`, which the one-kilobyte ceiling
above already guards, so a `Peer` change never trips it and a new `Conn` field
always does. As with every gated number, crossing it is a design event: the
constant moves here and in `loop.zig` together.

Those two are the headline numbers, not the only gated costs. The same
`zig build check` test suite also pins the outbound `encodeMessage` allocation
count, the `op:resolve` record's single allocation, the model value-tree struct
sizes, the GC-churn live-heap reclaim, and a zero-allocation steady hosted-vat
turn. The wire-path budget holds as a set, not only at the inbound floor.

Wall-clock time is gated too, as a tripwire rather than a precision
instrument. `zig build perf-check` (a member of `check`) runs the two hot-path
benches in ReleaseFast and holds three ceilings, owned here: one warm inbound
dispatch turn under **2,000 ns**, one answered outbound send under **8,000
ns** (each the minimum of five batch means, roughly an order of magnitude over
the measured figures, so machine noise cannot cross them), and the
`op:gc-answers` release storm's ns/answer growing by at most **3.0x** from
Q=1,000 to Q=8,000 (a dimensionless ratio of the same code at two sizes, so
machine speed cancels out of it; a reintroduced per-position scan shows as
roughly Q-proportional growth against a measured noise floor near 1.2). A
tighter threshold would flake across hardware, and a gate that flakes is worse
than a print, so drift smaller than the tripwire remains the printed benches'
and `bench-site-report`'s job. The ceiling constants live at the top of
`bench/dispatch_scaling_bench.zig` and `bench/outbound_bench.zig`, citing this
rung; crossing one is a design event, and so is raising one — the number moves
here and in the constant together (ADR-0073).

What stays open on this rung is pushing the opt-in live harness
(`bench-peer-scaling --live`) toward the full 500k target on a box with the
ulimit headroom — the harness exists; full-N runs are machine work, not missing
API. The footprint above is the protocol core measured in-process. The
completion loop's read buffers come from a shared backend-owned pool (ADR-0054),
so an idle connection holds zero read-buffer bytes. The core's obligation (never
being what makes 500k impossible) is the part this rung defends, and it now does.

## Rung 3: A Hosted Application

This rung is held.

An application riding pancake is what proves the ergonomics are real and not
just asserted, and it finds the API edges no conformance suite reaches. The
accountability application runs on pancake's own runtime over a real socket
(`zig build accountability`, with three-party attribution across handoff in
`accountability-three-party`). Three cross-language applications, `rooms`,
`tasks`, and `tools`, exercise the `connect`, `fetch`, `spawn`, and `send`
surface from five languages on one wire. Every rough edge such an application
finds is a bug against the ergonomics half of the performance-and-ergonomics
contract, not feedback to file for later.

## Rung 4: The C ABI Dogfood

This rung is held.

A library whose consumers reach it only through its public headers cannot lie
about that surface. The Rust consumer (`zig build rust-dogfood`) and the
per-language dogfoods (`zig build bindings`) prove consumability; the four
`*-goblins-interop` gates prove each binding holds a real OCapN conversation
through the ABI. The header itself is generated from the Zig source and
drift-gated.

## Rung 5: The Netlayer Frontier

The netlayer is a contract with four residents (`tcp`, `keyed-tcp`, `inproc`,
iroh). The encrypted iroh channel is discoverable (dial-by-id), identity-unified,
and served at scale by the ADR-0057 completion loop (`iroh.Backend` + Bridge,
gated by `iroh-loop`), pancake to pancake. That loop is the scale path every
binding parks on (the public C ABI is loop-only; gated by `bindings-iroh-loop`).
Opt-in live-socket scale measurement is `bench-peer-scaling --live`; the open
work is pushing that harness toward the full 500k budget on a scale box.

`net` owns `std.Io` behind the core/adapters boundary. The TCP netlayer, the
stream-framing `Connection`, and the accepted and outbound completion-loop paths
are shipped and gated. Linux uses io_uring, and macOS/BSD use kqueue.

The netlayer is a pluggable contract, not a privileged built-in (ADR-0043). A
`Netlayer` is a runtime resident. The driver's `connectVia` and `acceptVia`
dispatch to it by the locator's transport symbol, over a transport-generic
`Connection`. There are four real residents. `tcp` is the cleartext socket
transport. `keyed-tcp` (ADR-0075) reuses those sockets under a key designator.
The in-process `net.inproc` (ADR-0047) is a genuinely different one: a
designator switchboard wiring two in-process byte pipes, with no sockets and no
file descriptors. The iroh resident (`net/transport/iroh.zig`, ADR-0055) is the
encrypted one: each connection is a bidirectional QUIC stream from a real iroh
endpoint, dialed by Ed25519 endpoint id, carried by the `transports/iroh` Rust
sidecar so the pure-Zig archives stay pure Zig, and proven live by
`zig build iroh-interop`. All four drive through the same `connectVia` /
`acceptVia` path and complete the same verified handshake, and adding each one
edited no driver, core, or contract file, which is what proves the contract is
transport-general rather than socket-shaped; a caller's own transport slots in
the same way. (A test-defined `x-loopback` transport also exercises the
dispatch from outside the tree, though it rides tcp underneath.)

Server-side hosting is at parity across the surface. The native driver hosts
with `driver.listen` (each `accept` hands back an owning `driver.Session`),
with `driver.acceptTcp` as the buffer-explicit spelling, both proven by the
driver loopback tests; above the one-connection face, the sans-io
`driver_core.Host` owns identity, the node, and both three-party handoff halves
(ADR-0072), with `driver.Bridge` + `completion.Loop` as the native Zig multi-session CapTP path
over it and every binding riding the same core through `libpancake_driver`
(`pancake_host_*`). The hermetic three-host scenario and the live
`goblins-handoff` driver pin that surface. Every binding listens as well as dials; the Rust
connection test and the Racket smoke gate their host sides. The inbound read
path is production-shaped. Read buffers size the steady state, and an admissible
frame larger than the buffer rides a bounded owned spill shared by every inbound
consumer (ADR-0041). That path is proven down to a 64-byte buffer over a real
socket. The completion loop's write path is bounded to match. When pending reply
bytes cross a high-water mark, that connection's reads park until the partner
drains them, and burst capacity frees on drain (ADR-0042). A scripted fake
backend proves the exact park and resume order.

Open work on this rung is pushing the opt-in live-socket harness
(`bench-peer-scaling --live`) to full-target N on a suitable box, plus a Windows
completion backend. Everything else has landed: the encrypted channel pancake to pancake
(`iroh-interop`), its dial-by-id discovery, key unification, and durable-identity
capstones on the same gate, and every binding's adoption of the loop surface
(`bindings-iroh-loop`, Deno matching it without a gated row). Two completion-loop
scale substrates ship today: the TCP path is `net.TcpLoop` + `driver.Bridge` +
`driver_core.Host` (ADR-0076, gated by `zig build tcp-loop` and the
handoff-across-one-loop test — the only loop path proven for cross-connection
handoff), and the iroh path shares that bridge via `iroh.Backend` (ADR-0057,
gated by `iroh-loop`), including redeem dial (`iroh-bridge-redeem`).
`bench-peer-scaling`'s `served` row extrapolates per-connection core state;
`--live` reports measured loopback figures at stepped N.
The TCP blocking pump stays a single fiber by contract (ADR-0053): it serves
cooperative request/response, and a partner that streams without draining is the
completion loop's workload, not a pending fiber split.

## Reading the ladder

Rungs 1, 3, and 4 are held and stay held by gates. They reopen only if a gate
weakens, and weakening a gate is the change that needs the argument. Rung 2's
in-process budget is held by gates; its live-socket harness is opt-in
(`bench-peer-scaling --live`), with full-N measurement still machine work on
rung 5. Rung 1 is also the standing discipline every protocol-touching diff pays into.
Rung 5 is where new work toward the vision starts.

For the flatter backlog, with each item checked against the current tree, see
[the remaining-work list](roadmap.md).
