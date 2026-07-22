# pancake: The Ladder

This is the dependency-ordered route toward 1.0, and the record of where each
step on the ladder stands. [`vision.md`](vision.md) says where pancake is going;
this file says what has to be true, and in what order, before that destination
can be claimed, and which steps the build check already proves. When a step's
standing changes, this file changes in the same diff. It is docs that must
match today's code; see [CONTRIBUTING.md](../CONTRIBUTING.md).

The order is an argument, not a wish list: an application built before
conformance would bake protocol bugs into its API, and a second netlayer
before a first consumer would optimize a boundary nobody has pushed on yet.

## Standing discipline: structure as enforcement

This is the floor every step on the ladder stands on, not a step itself. Each `src/` layer
is its own build.zig module with a one-way import table, so codec-neutrality
of the session, codec isolation, and the core/adapters split are compile
errors to violate (ADR-0040); Syrup and Cap'n Proto are separate modules
below that and can't import each other either (ADR-0048). The DAG lives in
one place, the `layer_table` in build.zig, and `zig build check` runs the
architecture check step that verifies it against the tree, including bans a module graph
alone can't express: no `std.Io` or threading in the core, no platform
syscalls in portable code. Any doc's claim about layering defers to that
table.

## Step 1: Conformance For The Portable Sync Core

This step is held by verification, and its breadth is still growing.

OCapN behavior, live Spritely Goblins conversation, the upstream OCapN suite,
and Zig-local protocol scenarios are the conformance authority. pancake is the
implementation. No other implementation is the source of truth for its
semantics. A semantic claim without a scenario or fixture is a wish.

Live Goblins and the upstream suite are the strongest external Syrup check.
The pancake-authored Syrup corpus (`zig build oracle-check`, held against the
upstream encoder by `fixture-gen-check`) proves that pancake's record shapes
match that encoder. It does not prove independent Goblins emission.

Today's proof also includes pancake-to-pancake cross-codec traces, the live
Goblins conversation both ways (`goblins-interop`), three-party handoff as
recipient and as gifter (`goblins-handoff`, `goblins-gift`, and the binding
`*-goblins-handoff` / `*-goblins-gift` steps), inbound `op:gc-exports` from a
Goblins vat (`goblins-gc`),
and the upstream suite (`ocapn-conformance`). `goblins-gc` covers inbound
export release only, not `op:gc-answers` or binding finalizer GC.

What keeps this step open is breadth, not machinery. A change that touches a
spec edge with no scenario yet adds the test. Promise pipelining, three-party
handoffs, sturdyref enlivenment, and attenuated delegation carry the most
weight. Goblins-shaped extensions get flagged wherever they appear.

## Step 2: The Performance Contract, In Numbers

The per-session footprint budget is held by the build check. Live-socket measurement
is opt-in (`bench-peer-scaling --live`, Phase 2), and it reports measured
RSS and ns/turn at stepped N rather than only extrapolating the in-process
row.

The 500k-connection destination is a budget, not a claim, and a budget is
only real once a check step defends it. A steady-state `op:deliver` to a live
export costs exactly one heap allocation, the owned-frame copy the event
model requires, pinned by `test/engine/alloc_budget_test.zig`. `engine.Peer`
carries a `comptime` ceiling on its own struct size, so staying under **1
KiB** of inline session state is a compile error to break, and
`test/engine/footprint_budget_test.zig` holds the warmed total (struct plus
session heap) at or under **2 KiB** per session; 500,000 sessions at 2 KiB
is under 1 GiB of protocol-core state. `zig build bench-peer-scaling` reports
the live measured numbers and extrapolates to 500k; `zig build check` runs
it in `--smoke` mode plus both budget checks.

The completion loop wraps each `Peer` in one `Conn` slot, which carries a
ceiling of its own. A `Conn`'s bookkeeping beyond the embedded `Peer` (slot
state, the outbound queue's two buffer headers, the spill header, the
intrusive free/starved link, and the in-flight and app-context words)
measures 112 bytes on every backend, and a `comptime` assertion in
`net/completion/loop.zig` holds it at or under **128 bytes**
(`conn_slot_overhead_bytes`, headroom for park-kill bookkeeping). Crossing it
is a design event: the constant moves in `loop.zig` and in this standing
together.

Those two are the headline numbers, not the only checked costs. The same test
suite also pins the outbound `encodeMessage` allocation count, the
`op:resolve` record's single allocation, the model value-tree struct sizes,
the GC-churn live-heap reclaim, and a zero-allocation steady hosted-vat turn.

Wall-clock time is checked too, as a tripwire rather than a precision
instrument. `zig build perf-check` (part of `check`) runs the two hot-path
benches in ReleaseFast and holds three ceilings, each the minimum of five
batch means so machine noise can't cross them: a warm inbound dispatch turn
under **2,000 ns**, an answered outbound send under **8,000 ns**, and the
`op:gc-answers` release storm's ns/answer growing by at most **3.0x** from
Q=1,000 to Q=8,000. That ratio is dimensionless and sits against a noise
floor near 1.2, so a reintroduced per-position scan would show as roughly
Q-proportional growth. A tighter threshold would flake across hardware, so
smaller drift stays the printed benches' job. The ceilings live at the top
of `bench/dispatch_scaling_bench.zig` and `bench/outbound_bench.zig`;
raising one is a design event same as crossing one (ADR-0073).

What stays open is pushing the opt-in live harness toward the full 500k
target on a box with the ulimit headroom for it: the harness exists, and
this is machine work, not missing API.

## Step 3: A Hosted Application

The proofs below already hold this step.

An application riding pancake proves the ergonomics are real, not just
asserted, and finds API edges no conformance suite reaches. The
accountability application runs on pancake's own runtime over a real socket
(`zig build accountability`, with three-party attribution across handoff in
`accountability-three-party`). Three cross-language applications, `rooms`,
`tasks`, and `tools`, exercise the `connect`, `fetch`, `spawn`, and `send`
surface from five languages on one wire. A rough edge any of them finds is
a bug against the ergonomics contract, not feedback to file for later.

## Step 4: The C ABI Binding Check

The proofs below already hold this step.

A library whose consumers reach it only through its public headers cannot
lie about that surface. The Rust consumer (`zig build rust-dogfood`) and the
per-language binding checks (`zig build bindings`) prove consumability; the
four `*-goblins-interop` check steps prove each binding as a Goblins client
holds a keyed v1.0 Syrup conversation (handshake, `enliven` + dedup, deliver /
resolve on echo) through the C ABI, not the Zig listener, actor-hosting,
projection, or break legs (`goblins-interop` owns bidirectional native proof).
Binding `*-goblins-handoff` / `*-goblins-gift` prove recipient and gifter
handoff roles over that same C ABI. The header itself is generated from the Zig
source and checked against drift.

## Step 5: The Netlayer Frontier

The netlayer is a pluggable contract, not a privileged built-in (ADR-0043),
with these residents today. `tcp` is the cleartext socket transport.
`keyed-tcp` (ADR-0075) reuses those sockets under a key designator.
`net.inproc` (ADR-0047) wires in-process byte pipes with no sockets or file
descriptors. `iroh` (`net/transport/iroh.zig`, ADR-0055) dials a real iroh
endpoint by Ed25519 id over an encrypted QUIC stream, carried by the
`transports/iroh` Rust sidecar so the pure-Zig archives stay pure Zig,
proven live by `zig build iroh-interop`. `webrtc`
(`net/transport/webrtc.zig`, ADR-0089) carries a session over a peer-to-peer
DataChannel, DTLS-encrypted and carried by the `transports/webrtc` Rust
sidecar, proven live by `zig build webrtc-interop`. Every resident but `webrtc`
drives through the same `connectVia`/`acceptVia` dispatch and handshake over one
transport-generic `Connection`; `webrtc` has no dialable address, so it is
reached by a signaling exchange first and then runs the identical keyed
handshake over the opened channel. Adding each transport touched no driver,
core, or contract file, which is why the contract counts as transport-general
rather than socket-shaped. `net` owns `std.Io` behind the core/adapters boundary, on
io_uring for Linux and kqueue for macOS/BSD.

Server-side hosting is at parity across residents: the native driver hosts
with `driver.listen` and the buffer-explicit `driver.acceptTcp`. Above the
one-connection face, the sans-io `driver_core.Host` owns identity, the node,
and both three-party handoff halves (ADR-0072); `driver.Bridge` +
`completion.Loop` is the multi-session CapTP path over it, and every
binding rides the same core through `libpancake_driver`'s `pancake_host_*`
family and can listen as well as dial. An inbound frame larger than the
read buffer rides a bounded owned spill shared by every consumer
(ADR-0041), proven down to a 64-byte buffer over a real socket, and the
write path is bounded to match: past a high-water mark of pending reply
bytes, a connection's reads park until the partner drains them, freeing
burst capacity on drain (ADR-0042).

Two completion-loop scale substrates ship: TCP (`net.TcpLoop` +
`driver.Bridge` + `driver_core.Host`, ADR-0076, verified by `tcp-loop`, the
only path proven for handoff across a loop's connections) and iroh, sharing
that bridge via `iroh.Backend` (ADR-0057, verified by `iroh-loop`, including
redeem dial via `iroh-bridge-redeem`). The encrypted iroh channel is
discoverable by node id and identity-unified, and every binding parks on
this loop since the public C ABI is loop-only (`bindings-iroh-loop`).
`bench-peer-scaling`'s `served` row extrapolates per-connection core state;
its opt-in `--live` mode reports measured loopback figures at stepped N.
The TCP blocking pump stays a single fiber by contract (ADR-0053): a
partner that streams without draining is the completion loop's workload,
not a reason to split that fiber.

Open work on this step is pushing the live-socket harness to full-target N on
a suitable box, plus a Windows completion backend; everything else has landed.
Windows/IOCP, macOS runtime CI, and browser WASM are backlogged platform rocks.
Their blockers and flip conditions live in [roadmap.md](roadmap.md) section 2.
Claiming
500k as an achievement waits on printed `--live` or loop figures in the same
diff that updates this standing.

## Reading the ladder

Steps 1, 3, and 4 are held and stay held by the build check; they reopen only
if a check step weakens, and weakening a check step is the change that needs
the argument. Step 2's in-process budget is held by the build check too, with
the full-N live-socket measurement still open on step 5. Step 1 doubles
as the standing discipline every protocol-touching diff pays into. Step 5 is
where new work toward the vision starts.

For the flatter backlog, with each item checked against the current tree,
see [the remaining-work list](roadmap.md).
