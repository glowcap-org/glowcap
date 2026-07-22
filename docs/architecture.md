# pancake Architecture

pancake is an OCapN / CapTP core you use as a library. It makes visible what a
library usually hides: whether a frame is owned or borrowed, where a copy or
allocation happens, which wire format is in play, and where I/O and scheduling
live.

## Design Contract

Wire-path allocation and copy are forbidden, intentional, or measured
([vision](vision.md)). Session state is authoritative; codecs parse and
render. The engine stays synchronous and does no I/O. Bindings prove the C
ABI is consumable; they are never protocol authority
([capabilities](capabilities.md), [shipped](shipped.md)).

Protocol evidence: live Goblins (`conformance/goblins-peer/`), the upstream
OCapN suite, and `test/oracle/` (see
[`test/oracle/README.md`](../test/oracle/README.md)).

## Core Boundary

The canonical core owns protocol semantics and nothing else: no sockets, no
`std.Io`, no background tasks, no hidden scheduler, and no process-level
runtime object. Dispatch runs in a layer called `engine`, not `runtime`,
because it is caller-driven rather than an ambient executor.

The layering is compiler-enforced: each `src/` layer is a build.zig module
with a one-way import table, so a cross-layer reach is a compile error
(ADR-0040). The same rule runs one level deeper, so Syrup and Cap'n Proto
cannot import each other and only the codec root knows both (ADR-0048). The
four layers that are the OCapN / CapTP protocol itself, model, codec,
session, and engine, live under `src/ocapn/` (ADR-0044), and `src/root.zig`
curates the one public `pancake` namespace over all of them.

Adapters feed inbound frames, call `Peer.step`, drain outbound frames, and
poll events; they may use `std.Io`, native transports, or host callbacks,
but add no CapTP behavior of their own.

## Netlayer (`net`)

`net` is the one layer where `std.Io` enters; `arch-check` keeps every other
layer free of it (ADR-0040). CapTP stays transport-agnostic above it.

One decoder (`decodePrefix`) finds frame boundaries (ADR-0029).
`Connection.pumpOver` folds that parser over a borrowed reader/writer
(ADR-0030, ADR-0043). Residents plug in through a vtable: `tcp`,
`keyed-tcp` (ADR-0075), `inproc` (ADR-0047), and iroh QUIC (ADR-0055).
Inbound frames are capped; oversize bursts use a bounded spill so memory
does not scale with `max_frame_bytes` (ADR-0041). Outbound pending bytes
park reads at a high-water mark (ADR-0042). Shared read buffers are
ADR-0054. The blocking pump is one fiber (ADR-0053); streaming partners
belong on the completion loop (ADR-0057 for iroh). Crossed hellos are
resolved in the host core below, not here (ADR-0068).

Open edges (cleartext TCP, no TLS-on-TCP, discovery limits, no
Goblins-over-iroh): [boundaries](boundaries.md#netlayer).

## Actors And Local Time-Travel (`actors`, `persistent`)

The `actors` layer owns opt-in local time-travel. A `Vat` can snapshot its
local actor heap and restore it later, sharing each actor's state behind a
non-atomic refcounted box so the operation is O(objects) with no byte copy;
mutable actors get copy-on-write, and persistent actors get a functional
`become` (ADR-0060). Time-travel is local only: a snapshot never captures
session state, and a restore never rewinds a peer.

The sibling `persistent` leaf supplies one refcounted-HAMT `PersistentMap`
(ADR-0061), so a persistent actor's incremental `become` runs in O(log n)
with structural sharing; it imports nothing and does not sit on the public
namespace.

## Application Surface (`driver`)

The `driver` layer sits above the actor turn loop and the netlayer; it is the
one place allowed to touch `std.Io` and the actor vat at the same time.

Four names, one ladder:

| Name | Owns |
| ---- | ---- |
| `engine.Peer` | One conversation's sans-io engine: feed, `step`, drain, events |
| `driver.Session` | One partner for an app: `connect` / `listen`, `fetch`, blocking `call` |
| `Host` (`driver_core`) | Many sessions, one identity, vows, handoff router, crossed hellos |
| `driver.Bridge` | Answers the Host action queue over a completion loop (bindings use `libpancake_driver`) |

`driver.BlockingSession` binds a `Served` (sans-io vat-serve core) to a live
`net.Connection` over one caller-owned `Peer`. Owning `Session` sits above
that: `call` returns fulfilled, broken, or `.give` (a typed three-party
introduction). With a Host in play, that give settles as the introduced
capability inside the wait: no separate redeem verb for ordinary app code
(ADR-0072, ADR-0079). Human teaching of the hard move lives on the site
Concepts page (`zig build docs-serve`) and in example chapter 02.

### Options vocabulary (ADR-0082)

Several Options structs share field names because they share a concept. They
are deliberately not merged into one mega-struct:

| Surface | Owns | Shared names |
|---------|------|--------------|
| `session.SessionLimits` | CapTP table and admission caps | `max_frame_bytes`, `queue_cap`, … |
| `Host.Options.limits` | Full limits projected onto every minted peer | same `SessionLimits` |
| `SessionOptions.frame_cap` | One owned session's admission | maps to `max_frame_bytes` |
| `completion.Loop.Options.frame_cap` | Read-buffer pool sizing | not peer admission |
| `Loop.Options.outbound_high_water` / `fan_in_throttle` / `park_kill_ms` | Backpressure and reclaim | loop I/O only |
| `Host.Options.bootstrap_durability` | Registry posture (`ephemeral` live; `durable_bootstrap` panics at init until an embedder store) | Host only |

Default Host admission is 1 MiB; the loop's `frame_cap` defaults to 64 KiB.
Raise either for larger frames or bigger steady-state chunks.
`driver.ResilientClient` sits above the loop: it classifies `DialError`s,
rebuilds dial plus handshake as a new CapTP session, and budgets discovery at
3000 ms times 24 attempts. Embedder metrics ride `Loop.Options.on_park` and
`ResilientClient.on_dial_outcome`.

Below all of this sit the explicit-ownership escapes, thin wrappers such as
`connectTcp` that still hand the caller the allocator, buffers, and peer
directly. A consumer who outgrows the surface entirely reaches the raw peer
through `BlockingSession.peer`.

## Session Representation

Session state is authoritative, and it is data-oriented. The protocol hands
out dense, monotonically increasing integer positions
(`next_export_position++`, `next_outbound_answer++`, plus positions the
partner allocates), and the session spends them as table keys instead of
re-deriving them by scanning.

- Exports, imports, and inbound/outbound answers are each O(1) position-keyed
  maps, not linearly scanned lists, and CapTP's three position namespaces
  stay three separate tables rather than one merged map (ADR-0080). They do
  unify on reference identity, though: a near export, a far import, a
  promise, and an answer are one `Slot` sum type, with the four wire
  descriptors computed from that slot at render time instead of stored, so
  pipelining, resolution, and handoff read one shape instead of four.
  `ImportTable` separately caps partner-driven imports.
- An answer row keeps its hot state-machine fields inline; its pipelining
  payload hangs off a pointer allocated only once an answer actually accrues
  one. Byte-keyed tables are hashed too: the `bootstrap` registry lives in
  one per-session byte arena, and the handoff `gifts` table is vat-scoped
  with precise per-row frees, since a re-deposit replaces a row (ADR-0056).
- The steady-state inbound path validates straight from the borrowed codec
  projection and only materializes an owned message when a deliver must be
  queued for pipelining, so a deliver to a live export costs exactly one
  allocation, a budget `test/engine/alloc_budget_test.zig` asserts. Argument
  sequences expose a forward iterator for the same reason: a loop that
  instead re-scans the list with random-access lookups is quadratic.
- Recursive argument walks are bounded by `SessionLimits.max_nesting_depth`,
  so an attacker-nested inbound frame fails loudly instead of overflowing
  the stack (ADR-0025), and dispatch runs an exhaustive
  `switch (session.state)` admission check so a new state variant can never
  silently inherit "admit everything."
- Float equality uses `Object.is`, not IEEE `==`: every NaN equals every
  other NaN, and `+0.0` is distinct from `-0.0` (ADR-0021).

pancake never reuses a position it allocates itself, so its own positions
stay stable keys for the session's life. A partner is not bound by that
policy: CapTP lets a peer reuse an answer position once garbage-collected.
The slot tables still need no generational handle, though, because a
position-keyed row is removed at GC entirely, so a partner's reuse always
lands on a cleared, indistinguishable table. The tables are hashed rather
than flat vectors for a related reason: a hostile peer could otherwise name
a sparse import position and force a flat array to grow to that index, a
memory denial-of-service the hash avoids.

## Memory Contract

`Frame` owns wire bytes; `FrameView` borrows wire bytes for a bounded call
scope, and session state must never retain borrowed wire memory. The decode
split follows the same rule: `decodeBody` projects a borrowed semantic view
over frame bytes, while `decodeOwned` materializes an owned value only when
persistence, tests, or a cross-boundary handoff requires one.

`FrameShape` also distinguishes byte storage from word-aligned storage (the
`word` shape is 8-byte-aligned with a length divisible by 8): Syrup is
byte-framed, Cap'n Proto is word-framed, and a codec-neutral core keeps that
distinction explicit instead of flattening every frame to generic bytes.

## Copy Budget

A copy must be named at the boundary where it happens; it is never the
default way a frame moves.

- `Frame.initOwned` and `Frame.initExternal` both adopt existing storage
  without copying, the latter calling a supplied release hook on `deinit`;
  `Frame.view` never allocates or copies.
- `Peer.sendCopying` names its queueing cost right in its name.
  `Peer.recvBorrowed` retains transient borrowed wire bytes with exactly one
  named copy, while `Peer.feedOwned` and `Peer.step` move an already-owned
  frame into the surfaced event with zero copies.
- A surfaced `Event` keeps its originating frame in the negotiated codec, so
  the C ABI hands back those exact bytes without decoding and re-encoding
  them.
- `test/support/frame.zig` is the one place allowed to copy caller bytes
  into frame-owned allocations, for tests and fixtures; production `Frame`
  has no copy constructor.
- An outbound C ABI call returns a managed frame with a release callback.

## C ABI Contract

Opaque handles, fixed-width codes, `ptr + len` views, explicit release,
callbacks with caller context. Archives compose à la carte (ADR-0059), no
umbrella library: `libpancake_ocapn`, `libpancake_net`,
`libpancake_net_transport_tcp`, `libpancake_net_transport_inproc`,
`libpancake_net_transport_iroh`, `libpancake_net_transport_webrtc`,
`libpancake_driver`. Allocation rides a
`PancakeContext` (ADR-0031). Archive table, link recipe, and first program:
[consuming-from-c](consuming-from-c.md).

Each language binding (Rust, TypeScript, Python, and Racket) drives the pump
cycle directly against the C ABI entry points: it feeds inbound bytes with
`pancake_host_session_feed_bytes`, answers host actions from
`pancake_host_next_action`, and drains outbound frames with
`pancake_host_session_take_outbound`. There is no callback orchestration layer
between a binding and those calls, because each binding's own async runtime
schedules the cycle, and callback indirection composes poorly with async/await.

## Examples As Contract

Examples are build targets, not snippets.
[`examples/README.md`](../examples/README.md) indexes the Zig chapters and C
programs (`frame_view`, `context_alloc`, `echo_peer`, `compose_transports`,
host embedder pump). `zig build check` runs them.

## Product Surfaces (`cli/`, `apps/`) And Dev Tools

The installable `pancake` binary consumes the public `pancake` module. It is not
a new protocol layer and not part of `libpancake_*`
([ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md)). Sources
live at repo-root `cli/`. Argv parse, scoped help, and completion share
`cli/cmd/`; CapTP leaves also feed REPL lines and curated MCP `tools/call`.
I/O, identity files, XDG state-dir locking, MCP stdio lifecycle, and `app rooms-peer`
presence stay in this adapter. The `rooms-peer` install name is a thin forwarder
to `pancake app rooms-peer`. When the job is to call a peer, host a temporary
listener, open a REPL, or script CapTP from a shell, this binary is the
surface: walkthrough in [`docs/cli.md`](cli.md). Present edges:
`docs/shipped.md` and `docs/boundaries.md`.

First-party product apps that ship as their own binaries live under
[`apps/`](../apps/), not under maintainer tooling
([ADR-0085](decisions/adr/ADR-0085-repository-product-and-devtool-layout.md)).
Demos stay in [`apps/`](../apps/). The usual dev-tool verbs
are top-level [`test/`](../test/), [`tools/check/`](../tools/check/) (build
checks), and [`tools/gen/`](../tools/gen/) (codegen), with
[`tools/c-abi/`](../tools/c-abi/) for the C-ABI operator toolkit.
