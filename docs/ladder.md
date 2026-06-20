# pancake — The Ladder

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

## Standing discipline — structure as enforcement

This is the floor every rung stands on, not a rung itself. The layer DAG is not
a convention. Each `src/` layer is an internal build.zig module with a one-way
import table, so codec-neutrality of the session, codec isolation, and the
core/adapters split are compile errors to violate (ADR-0040). Below the codec
layer, each sibling wire codec is its own module, so Syrup and Cap'n Proto
cannot import each other either (ADR-0048). The DAG is one declaration, the
`layer_table` in build.zig, and the arch gate checks it against the tree: a
granted edge no file imports fails, and so do the content bans a module graph
cannot express, no `std.Io` or threading in the core, and no platform syscall
namespaces in portable code. `zig build check` runs that gate. A claim about
layering in any doc defers to the `build.zig` table. The `src/` layout is
settled; keeping it settled is part of this standing discipline, never a
session's mission.

## Rung 1 — Conformance For The Portable Sync Core

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
machinery the beachheads stand on — promise pipelining, three-party handoffs,
sturdyref enlivenment, and attenuated delegation — carries the most conformance
weight, and Goblins-canonical extensions get flagged wherever they appear.

## Rung 2 — The Performance Contract, In Numbers

The per-session footprint budget is held by gates. The live-socket measurement
is still open.

The 500k-connection destination is a budget, not a claim, and a budget is only
real once a gate defends it. Two halves of the wire-and-session cost are
mechanical checks. The wire-path allocation floor is exact: a steady-state
`op:deliver` to a live export costs exactly one heap allocation, the owned-frame
copy the event model requires, pinned by `test/engine/alloc_budget_test.zig`.
The per-session footprint is bounded: `engine.Peer` carries a `comptime` ceiling
on its own struct size, so a session's inline state staying under one kilobyte
is a compile error to break, and `test/engine/footprint_budget_test.zig` holds
the warmed total — struct plus session heap — at or under 2 KiB per connection.
2 KiB times 500_000 sessions is under 1 GiB of protocol-core state.
`zig build bench-peer-scaling` reports the live measured numbers and
extrapolates to 500k; `zig build check` runs it in `--smoke` mode and runs both
budget gates.

Those two are the headline numbers, not the only gated costs. The same
`zig build check` test suite also pins the outbound `encodeMessage` allocation
count, the `op:resolve` record's single allocation, the model value-tree struct
sizes, the GC-churn live-heap reclaim, and a zero-allocation steady hosted-vat
turn. The wire-path budget holds as a set, not only at the inbound floor.

What stays open on this rung is the part that needs a socket, not a number on
paper. The footprint above is the protocol core measured in-process. The
completion loop's read buffers come from a shared backend-owned pool (ADR-0054),
so an idle connection holds zero read-buffer bytes, but accept throughput,
syscalls per turn, and resident-set growth under a real 500k-connection run
still need a load harness. That measurement belongs where the budget meets a
socket, on rung 5. The core's obligation — never being what makes 500k
impossible — is the part this rung defends, and it now does.

## Rung 3 — A Hosted Application

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

## Rung 4 — The C ABI Dogfood

This rung is held.

A library whose consumers reach it only through its public headers cannot lie
about that surface. The Rust consumer (`zig build rust-dogfood`) and the
per-language dogfoods (`zig build bindings`) prove consumability; the four
`*-goblins-interop` gates prove each binding holds a real OCapN conversation
through the ABI. The header itself is generated from the Zig source and
drift-gated.

## Rung 5 — The Netlayer Frontier

The netlayer is a contract with three residents, the third of them the encrypted
iroh channel, now encrypted, discoverable (dial-by-id), identity-unified, and
served at scale by the ADR-0057 completion loop (`iroh.LoopHost`, gated by
`iroh-loop`), pancake to pancake. That loop is the netlayer's one I/O model, and
every binding parks on its readiness fd natively (gated by
`bindings-iroh-loop`). The open work is the live-socket half of the 500k budget.

`net` owns `std.Io` behind the core/adapters boundary. The TCP netlayer, the
stream-framing `Connection`, and the accepted and outbound completion-loop paths
are shipped and gated. Linux uses io_uring, and macOS/BSD use kqueue.

The netlayer is a pluggable contract, not a privileged built-in (ADR-0043). A
`Netlayer` is a runtime resident. The driver's `connectVia` and `acceptVia`
dispatch to it by the locator's transport symbol, over a transport-generic
`Connection`. There are three real residents. tcp is the socket transport. The
in-process `net.inproc` (ADR-0047) is a second, genuinely different one: a
designator switchboard wiring two in-process byte pipes, with no sockets and no
file descriptors. The iroh resident (`net/transport/iroh.zig`, ADR-0055) is the
third and the encrypted one: each connection is a bidirectional QUIC stream from
a real iroh endpoint, dialed by Ed25519 endpoint id, carried by the
`transports/iroh` Rust sidecar so the pure-Zig archives stay pure Zig, and
proven live by `zig build iroh-interop`. All three drive through the same
`connectVia` / `acceptVia` path and complete the same verified handshake, and
adding each one edited no driver, core, or contract file, which is what proves
the contract is transport-general rather than socket-shaped; a caller's own
transport slots in the same way. (A test-defined `x-loopback` transport also
exercises the dispatch from outside the tree, though it rides tcp underneath.)

Server-side hosting is at parity across the surface. The native driver hosts
with `driver.listen` (each `accept` hands back an owning `driver.Connection`),
with `driver.acceptTcp` as the buffer-explicit spelling, both proven by the
driver loopback tests. Every binding listens as well as dials; the Rust
connection test and the Racket smoke gate their host sides. The inbound read
path is production-shaped. Read buffers size the steady state, and an admissible
frame larger than the buffer rides a bounded owned spill shared by every inbound
consumer (ADR-0041). That path is proven down to a 64-byte buffer over a real
socket. The completion loop's write path is bounded to match. When pending reply
bytes cross a high-water mark, that connection's reads park until the partner
drains them, and burst capacity frees on drain (ADR-0042). A scripted fake
backend proves the exact park and resume order. `driver.LoopHost` packages the
accepted actor-hosting side, and `driver.LoopDialer` packages the client fan-out
side: both run keyed sessions through the same loop-backed connection lifecycle.

Open work on this rung is the live 500k footprint measurement that turns rung
2's budget into a number under real socket load, and a Windows completion
backend. Binding-side adoption of the loop surface has landed: every binding
(Deno, Python, Rust, Racket) wraps it; Python, Rust, and Racket are each gated
by a many-connection proof under `bindings-iroh-loop`, and Deno implements the
same surface. The encrypted channel itself exists, pancake to
pancake, behind ADR-0043 (`zig build iroh-interop` is the live proof), and its
identity-and-discovery capstones have since landed on the same gate:
**dial-by-id discovery** (a configurable, no-default `Reachability`; the gate
dials by node id alone with no direct-address hints), **key unification** (one
Ed25519 key as node id, locator designator, and session signing key), and
**durable identity** (a sturdyref outlives an endpoint restart). The endpoint id
is OCapN's self-authenticating designator, relays and hole-punching are
sidecar-internal, and `ocapn://<nodeid>.iroh` URI dialing reaches every binding
through the `libpancake_net_transport_iroh` C ABI companion library with an
explicit reachability. What remains is the **live-socket 500k measurement**: the
at-scale substrate itself has landed, the event-driven completion loop of
ADR-0057 (`iroh.LoopHost`, gated by `iroh-loop`) is the iroh netlayer's one I/O
model and multiplexes many connections through one readiness fd, not a thread
per connection, and `bench-peer-scaling`'s `served` row measures its
per-connection core state. The TCP blocking pump stays a single fiber by
contract (ADR-0053): it serves cooperative request/response, and a partner that
streams without draining is the completion loop's workload, not a pending fiber
split.

## Reading the ladder

Rungs 1, 3, and 4 are held and stay held by gates. They reopen only if a gate
weakens, and weakening a gate is the change that needs the argument. Rung 2's
in-process budget is held by gates; its live-socket measurement is rung 5 work.
Rung 1 is also the standing discipline every protocol-touching diff pays into.
Rung 5 is where new work toward the vision starts.

For the flatter backlog, with each item checked against the current tree, see
[the remaining-work list](roadmap.md).
