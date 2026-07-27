# pancake Architecture

pancake is an OCapN / CapTP core you use as a library. This page names the
layers, what each owns, and the memory and C ABI contracts between them.
Protocol evidence lives in live Goblins (`conformance/goblins-peer/`), the
upstream OCapN suite, and `test/oracle/` (see
[`test/oracle/README.md`](../test/oracle/README.md)).

## Core boundary

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
`keyed-tcp` (ADR-0075), `inproc` (ADR-0047), iroh QUIC (ADR-0055), and a
`webrtc` DataChannel (ADR-0089).
Inbound frames are capped; oversize bursts use a bounded spill so memory
does not scale with `max_frame_bytes` (ADR-0041). Outbound pending bytes
park reads at a high-water mark (ADR-0042). Shared read buffers are
ADR-0054. The blocking pump is one fiber (ADR-0053); streaming partners
belong on the completion loop (ADR-0057 for iroh). Crossed hellos are
resolved in the host core below, not here (ADR-0068).

Open edges (cleartext TCP, no TLS-on-TCP, discovery limits, no
Goblins-over-iroh): [boundaries](boundaries.md#netlayer).

## Actors and local time-travel (`actors`, `persistent`)

The `actors` layer owns opt-in local time-travel. A `Vat` can snapshot its
local actor heap and restore it later. The snapshot shares each actor's state
rather than copying it, behind a reference count, so the cost is one count per
actor and not one byte per byte. Mutable actors are copied only when a turn
would first write to shared state; persistent actors replace their state
outright with `become` (ADR-0060). Time-travel is local only: a snapshot never
captures
session state, and a restore never rewinds a peer.

The sibling `persistent` leaf supplies one refcounted-HAMT `PersistentMap`
(ADR-0061), so a persistent actor's incremental `become` runs in O(log n)
with structural sharing; it imports nothing and does not sit on the public
namespace.

## Application surface (`driver`)

The `driver` layer sits above the actor turn loop and the netlayer; it is the
one place allowed to touch `std.Io` and the actor vat at the same time.

Four names, from narrowest to widest:

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
are not merged into one mega-struct:

| Surface | Owns | Shared names |
|---------|------|--------------|
| `session.SessionLimits` | CapTP table and admission caps | `max_frame_bytes`, `queue_cap`, … |
| `Host.Options.limits` | Full limits projected onto every minted peer | same `SessionLimits` |
| `SessionOptions.frame_cap` | One owned session's admission | maps to `max_frame_bytes` |
| `completion.Loop.Options.frame_cap` | Read-buffer pool sizing | not peer admission |
| `Loop.Options.outbound_high_water` / `fan_in_throttle` / `park_kill_ms` | Backpressure and reclaim | loop I/O only |
| `Loop.Options.drain_kill_ms` | How long a condemned connection waits for its partner to read the abort | finite by default, unlike `park_kill_ms` |
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

## Session representation

Session state is authoritative, and it is data-oriented. The protocol hands
out dense, monotonically increasing integer positions
(`next_export_position++`, `next_outbound_answer++`, plus positions the
partner allocates), and the session spends them as table keys instead of
re-deriving them by scanning.

- Exports, imports, and inbound/outbound answers are each O(1) position-keyed
  maps, not linearly scanned lists, and CapTP's three position namespaces
  stay three separate tables rather than one merged map (ADR-0080). They do
  agree on what a reference *is*, though. A near export, a far import, a
  promise, and an answer are all one `Slot` type. The four wire descriptors are
  computed from that slot when a frame is rendered rather than stored beside
  it, so pipelining, resolution, and handoff all read one shape.
  `ImportTable` separately caps partner-driven imports.
- An answer row keeps its hot state-machine fields inline; its pipelining
  payload hangs off a pointer allocated only once an answer actually accrues
  one. Byte-keyed tables are hashed too: the `bootstrap` registry lives in
  one per-session byte arena, and the handoff `gifts` table is vat-scoped
  with precise per-row frees, since a re-deposit replaces a row (ADR-0056).
- The steady-state inbound path validates directly against the borrowed codec
  projection. It only builds an owned copy when a deliver has to be queued for
  pipelining. So a deliver to a live export costs exactly one allocation, which
  `test/engine/alloc_budget_test.zig` asserts. Argument sequences expose a
  forward iterator for the same reason: a loop that
  instead re-scans the list with random-access lookups is quadratic.
- Recursive argument walks are bounded by `SessionLimits.max_nesting_depth`,
  so an attacker-nested inbound frame fails loudly instead of overflowing
  the stack (ADR-0025), and dispatch runs an exhaustive
  `switch (session.state)` admission check so a new state variant can never
  silently inherit "admit everything."
- Float equality follows the OCapN same-value rule (the semantics JavaScript
  spells `Object.is`), not IEEE `==`: every NaN equals every other NaN, and
  `+0.0` is distinct from `-0.0` (ADR-0021).

pancake never reuses a position it allocates itself, so its own positions
stay stable keys for the session's life. A partner is not bound by that
policy: CapTP lets a peer reuse an answer position once garbage-collected.
The slot tables still need no generational handle, though, because a
position-keyed row is removed at GC entirely, so a partner's reuse always
lands on a cleared, indistinguishable table. The tables are hashed rather
than flat vectors for a related reason: a hostile peer could otherwise name
a sparse import position and force a flat array to grow to that index, a
memory denial-of-service the hash avoids.

## Memory contract

`Frame` owns wire bytes; `FrameView` borrows wire bytes for a bounded call
scope, and session state must never retain borrowed wire memory. The decode
split follows the same rule: `decodeBody` projects a borrowed semantic view
over frame bytes, while `decodeOwned` materializes an owned value only when
persistence, tests, or a cross-boundary handoff requires one.

`FrameShape` also records whether a frame is plain bytes or word-aligned
storage, where word-aligned means an address divisible by eight and a length to
match. Syrup frames are bytes and Cap'n Proto frames are words. A core that
serves both keeps the difference visible rather than flattening every frame
into anonymous bytes.

## Copy budget

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
callbacks with caller context. There is no umbrella library: you link the
archives you need and no others (ADR-0059). Two are always there,
`libpancake_ocapn` and `libpancake_net`, alongside `libpancake_driver` for the
byte-fed host. Then one archive per transport you actually use:
`libpancake_net_transport_tcp`, `libpancake_net_transport_inproc`,
`libpancake_net_transport_iroh`, `libpancake_net_transport_webrtc`.
Allocation goes through a `PancakeContext` (ADR-0031).
For the full archive table, a link recipe, and a first program, see
[consuming-from-c](consuming-from-c.md).

Each language binding drives the same three-step cycle against the C ABI. It
feeds inbound bytes in with `pancake_host_session_feed_bytes`, lets the host
run whatever that produced with `pancake_host_pump_drain`, and takes outbound
frames back out with `pancake_host_session_take_outbound`.

That middle step calls the hooks the binding registered. A binding must not
pop the raw action queue itself, and `meta-check` refuses one that tries.
Each binding's own
async runtime schedules the cycle, so pancake runs no background loop of its
own, and callback indirection composes poorly with async/await.

## Examples as contract

Examples are build targets, not snippets.
[`examples/README.md`](../examples/README.md) indexes the Zig chapters and C
programs (`frame_view`, `context_alloc`, `echo_peer`, `compose_transports`,
host embedder pump). `zig build check` runs them.

## Product surfaces (`cli/`, `apps/`) and dev tools

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
