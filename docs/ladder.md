# pancake: The Ladder

This is the dependency-ordered route toward 1.0, and the record of where each
step on the ladder stands. [`vision.md`](vision.md) says where pancake is going;
this file says what has to be true, and in what order, before that destination
can be claimed, and which steps the build check already proves. When a step's
standing changes, this file changes in the same diff.

The order is an argument, not a wish list: an application built before
conformance would bake protocol bugs into its API, and a second netlayer
before a first consumer would optimize a boundary nobody has pushed on yet.

## Standing discipline: structure as enforcement

This is the floor every step on the ladder stands on, not a step itself. A step
the build check holds reopens only if a check step weakens, and weakening a
check step is the change that needs the argument. Each `src/` layer
is its own build.zig module with a one-way import table. Three properties are
therefore compile errors to break rather than rules to remember: the session
knows nothing of codecs, the codecs know nothing of each other, and the core
knows nothing of the adapters (ADR-0040). Syrup and Cap'n Proto sit below that
as separate modules and cannot import each other either (ADR-0048). The DAG
lives in
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
semantics.

Live Goblins and the upstream suite are the strongest external Syrup check.
The pancake-authored Syrup corpus (`zig build oracle-check`, held against the
upstream encoder by `fixture-gen-check`) proves that pancake's record shapes
match that encoder. It does not prove independent Goblins emission.

Today's proof also includes cross-codec traces between pancake peers and a
live Goblins conversation in both directions (`goblins-interop`). Three-party
handoff is proven in both roles, by `goblins-handoff` and `goblins-gift` and
the same pair per binding. An inbound `op:gc-exports` from a Goblins vat is
covered by `goblins-gc`, and the upstream suite (`ocapn-conformance`) runs on
the same push. `goblins-gc` covers inbound
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
ceiling of its own. Beyond the `Peer` it embeds, a `Conn` carries its slot
state, two buffer headers for the outbound queue and the offset into the first
of them, the spill header, and two words for in-flight count and application
context. One more word is a link shared by three lists: the free slots, the
buffer-starved ones, and the ones parked under backpressure. The deadline
bookkeeping adds a timestamp and the flag saying which wait it answers. That comes to **128 bytes** on every backend, and a `comptime`
assertion in `net/completion/loop.zig` holds it there exactly
(`conn_slot_overhead_bytes`). The assertion is an equality rather than a
ceiling, so a field added to `Conn` fails the build instead of quietly spending
headroom nobody is watching. Changing it is a design event: the constant moves
in `loop.zig` and in this standing together.

On the ADR-0076 Bridge scale path the byte-fed host wraps each `Peer` in one
`HostSession` shell, the third per-connection static allocation, and it carries
a ceiling of its own. The shell embeds a `Served` and its `Vat` inline while the
`Peer` itself lives behind a pointer, and it measures **664 bytes**; a `comptime`
assertion in `driver/core/host.zig` holds it at or under **768 bytes**
(`host_session_struct_budget_bytes`). A field added to the shell, to `Served`, or
to the embedded `Vat` is a withdrawal from that budget at 500k, so crossing it is
a design event: the constant moves in `host.zig` and in this standing together.

Those three ceilings guard protocol-core state, and they are not the largest
per-connection cost. A live connection also holds an outbound queue, bounded at
`steady_outbound_bytes = 16 KiB` per buffer across the `front`/`back` pair
(`src/net/frame_stream.zig`), so a busy connection's steady ceiling is 32 KiB —
an order of magnitude above the core state the three budgets hold, and roughly
16 GiB at 500,000 connections. That number is retained capacity, not a floor: an
idle connection's queue is empty, and the shared read-buffer pool (ADR-0054)
means an idle connection holds no read buffer at all. It belongs here because a
reader who sees only the three small numbers will under-count a real deployment
by more than an order of magnitude.

Those are the headline numbers, not the only checked costs. The same test
suite also pins the outbound `encodeMessage` allocation count, the
`op:resolve` record's single allocation, the model value-tree struct sizes,
the GC-churn live-heap reclaim, and a zero-allocation steady hosted-vat turn.

Wall-clock time is checked too, as a tripwire rather than a precision
instrument. `zig build perf-check`, which `check` runs, builds the two
hot-path benches in ReleaseFast and holds three ceilings. Each is measured as
the smallest of five batch means, so ordinary machine noise cannot push a run
over one. A warm inbound dispatch turn stays under **2,000 ns**, an answered
outbound send under **8,000 ns**, and the `op:gc-answers` release storm's cost
per answer grows by at most **3.0x** from
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

A library whose consumers reach it only through its public headers cannot
lie about that surface, and the checks below already hold this step. The Rust consumer (`zig build rust-dogfood`) and the
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
sidecar, proven live by `zig build webrtc-interop`. Every resident except
`webrtc` goes through the same dial-and-accept dispatch and the same handshake,
over one connection type that knows nothing of the transport under it. WebRTC
is the exception because it has no address to dial: peers exchange signaling
first, and only then does the identical keyed handshake run over the channel
that opened. Adding any of the byte-stream residents touched no driver, core,
or contract file, which
is why the contract counts as transport-general rather than socket-shaped. That
exception was not free: `webrtc` needed a new
`DialPlan.signaling` arm in the dial classifier, a `PANCAKE_DIAL_SHAPE_SIGNALING`
constant in the C ABI, and a dialect arm in each binding, because "no dialable
address" is a shape the plan did not previously have. `net` owns `std.Io` behind the core/adapters boundary, on
io_uring for Linux and kqueue for macOS/BSD.

Server-side hosting is at parity across residents: the native driver hosts
with `driver.listen` and the buffer-explicit `driver.acceptTcp`. Above the
one-connection face, the sans-io `driver_core.Host` owns identity, the node,
and both three-party handoff halves (ADR-0072); `driver.Bridge` +
`completion.Loop` is the multi-session CapTP path over it, and every
binding rides the same core through `libpancake_driver`'s `pancake_host_*`
family and can listen as well as dial. A frame too big for the read buffer
spills into a bounded buffer that every consumer shares (ADR-0041); it is
proven with a read buffer as small as 64 bytes over a real socket. The write
path is bounded to match. Once a connection has too many reply bytes waiting,
its reads stop until the partner catches up, and the extra capacity is handed
back when they do (ADR-0042).

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

Open work on this step: pushing the live-socket harness to full-target N on a
suitable box, a Windows completion backend, and the two webrtc pieces the
[roadmap](roadmap.md) names — a signaling rendezvous the Host can reach without
a handoff give, and a completion-loop tier for DataChannels.
Windows/IOCP, macOS runtime CI, and browser WASM are backlogged platform rocks.
Their blockers and flip conditions live in [roadmap.md](roadmap.md) section 2.
Claiming
500k as an achievement waits on printed `--live` or loop figures in the same
diff that updates this standing.

For the flatter backlog, with each item checked against the current tree,
see [the remaining-work list](roadmap.md).
