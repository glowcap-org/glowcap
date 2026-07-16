# pancake Architecture

pancake is an OCapN / CapTP core you use as a library. It makes visible what a
library usually hides: whether a frame is owned or borrowed, where a copy or
allocation happens, which wire format is in play, and where I/O and scheduling
live.

## Design Contract

```text
protocol semantics: fixed, correct, interoperable
implementation overhead: aggressively minimized
```

Performance is part of that contract: every allocation and copy on the wire
path is forbidden, intentional, or measured. Setup follows the same rule,
so build steps stay obvious, examples compile, public artifacts keep the
plain `pancake` name, and no tooling layer hides ownership, allocation,
I/O, scheduling, or authority.

## Protocol Authority

OCapN behavior, Spritely Goblins wire fixtures, and pancake's own checked
protocol scenarios decide what the protocol means, and Zig expresses that
behavior directly. The Rust, Deno, Python, and Racket bindings prove the C
ABI is consumable; they are never the authority for the protocol's
semantics, and a binding earns a compatibility claim only after it has been
dogfooded.

A few invariants hold everywhere: semantics stay codec-neutral, session
state stays authoritative, the canonical engine stays synchronous and does
no I/O, frame ownership stays explicit with message views borrowed, and the
C ABI keeps every ownership promise it makes.

The oracle bridge under `test/oracle/` enumerates the shipped message model
and embeds a pancake-authored Syrup fixture corpus cross-checked against
upstream Syrup encoders rather than captured from Goblins (see
[`test/oracle/README.md`](../test/oracle/README.md)). The live Goblins peer
under `conformance/goblins-peer/` and the upstream OCapN conformance suite
carry the actual wire authority, and both gate every release.

## Core Boundary

The canonical core owns protocol semantics and nothing else: no sockets, no
`std.Io`, no background tasks, no hidden scheduler, and no process-level
runtime object. Dispatch runs in a layer called `engine`, not `runtime`,
because it is caller-driven rather than an ambient executor, dispatching a
session synchronously with no scheduler or tasks of its own.

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

`net` is the one layer where `std.Io` enters pancake; the architecture gate
keeps every other layer free of it, and only `driver`, the transport
archives, and the public root may import it (ADR-0040).

A single decoder, the active codec's `decodePrefix`, finds every frame
boundary in a stream and returns one of four verdicts: incomplete, decoded,
malformed, or too large, so there is no separate delimiter scanner
(ADR-0029), and a nesting limit rejects a deeply nested prefix before it can
overflow the stack. `net.Connection.pumpOver` folds that parser over a
borrowed reader and writer: one pump cycle flushes outbound frames, applies
one inbound frame without a second parse, and tells a graceful EOF apart
from a mid-frame truncation (ADR-0030, ADR-0043). `Connection` is
transport-generic, so any transport that can hand it a reader and a writer
can drive it; `net.tcp` is the only site where a socket meets `std.Io.net`.

A transport is a resident the runtime plugs in, not a privileged built-in
(ADR-0043): `net.netlayer.Netlayer` is a vtable that dials a locator into a
`Connection`, and the driver resolves a locator's transport symbol against a
caller-owned list, failing closed on an unknown one. Four residents satisfy
that contract today: `tcp`; `keyed-tcp`, reusing `tcp`'s sockets under its
own locator grammar (ADR-0075); the in-process switchboard `net.inproc`,
wiring a dialer and listener through byte pipes with no sockets (ADR-0047);
and the iroh QUIC netlayer (ADR-0055), the latter two registering without
an edit to the driver or the core.

`SessionLimits.max_frame_bytes` caps inbound frame size, turning an
oversized frame into a `resource_exhausted` abort. The read buffer is sized
for the steady state, not the largest admissible frame; an oversized frame
accumulates once in a bounded owned spill freed as soon as it drains, so
per-connection memory never scales with the cap (ADR-0030, ADR-0041,
ADR-0042, ADR-0054). Outbound memory is bounded the same way, parking reads
once pending reply bytes cross a high-water mark. The blocking pump stays a
single fiber, good for cooperative request/response; a partner that streams
without draining belongs on the completion loop instead (ADR-0053).
Crossed hellos, two peers dialing each other at once, are resolved one layer
up by the host core described below, not here (ADR-0068).

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

`driver.BlockingSession` binds a `Served`, the sans-io vat-serve core, to a
live `net.Connection` over one caller-owned `engine.Peer`, sparing a
networked app the hand-written open/pump/dispatch loop. Above that sits the
owning `driver.Session`, the one-partner application object: `driver.connect`
dials, `driver.listen` hosts, and `Session.call` blocks until the reply
settles, returning fulfilled, broken, or a `.give`, the typed introduction a
three-party handoff delivers.

A `Host` is the multi-session CapTP product: it owns one identity, one
`engine.Node`, the sans-io handoff router, many sessions, vows, and the
crossed-hellos tiebreak (ADR-0079). `driver_core` supplies its sans-io
version, banned from sockets and threads exactly like `engine` (ADR-0072).
An embedder, `driver.Bridge` over a completion loop or a language binding
over `libpancake_driver`, answers the Host's action queue: dial, flush,
close, entropy, settled or failed (ADR-0068, ADR-0072, ADR-0076). A call
whose answer is a three-party introduction settles as the introduced
capability itself, because the host claims the give and withdraws it inside
the wait; there is no separate redeem verb to call. Language bindings drive
the same `Host` through `pancake_host_*` rather than rebuilding this tier.

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
| `Host.Options.bootstrap_durability` | Registry posture (`ephemeral` live; `durable_bootstrap` refused at init until an embedder store) | Host only |

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
  `switch (session.state)` admission gate so a new state variant can never
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

Put together: inbound C ABI frames dispatch and transfer without copying,
engine-owned frames move by transfer, events return their originating frame
with no re-encoding, and outbound C ABI calls return a managed frame with a
release callback.

## C ABI Contract

The C ABI stays boring on purpose: opaque handles, fixed-width integer
discriminants, `ptr + len` byte views, explicit release functions, callbacks
that carry caller context, and clear return codes.

The C ABI ships as a set of composable per-family archives a consumer links
à la carte rather than one umbrella library (ADR-0059), composing the way a
C program composes by including two headers and linking two archives:

| Archive                           | Header                           | Exported family                                                                                                                                                                                                                   |
| --- | --- | --- |
| `libpancake_ocapn`                | `pancake_ocapn.h`                | the sans-io peer plus shared vocabulary: `pancake_abi_version`, `pancake_context_*`, `pancake_peer_*`, `pancake_uri_*`/`pancake_locator_*`, frame/event releases, `pancake_last_error`. Multi-session work uses `pancake_host_*` |
| `libpancake_driver`               | `pancake_driver.h`               | the byte-fed host tier (`pancake_host_*`): multi-session CapTP routing, vows, and three-party handoff an embedder feeds and drains itself (ADR-0072)                                                                                |
| `libpancake_net`                  | —                                | net-core base; exports no symbol of its own but holds its place in the link recipe                                                                                          |
| `libpancake_net_transport_tcp`    | `pancake_net_transport_tcp.h`    | `pancake_tcp_*` plus its own last-error pair                                                                                                                                                                  |
| `libpancake_net_transport_inproc` | `pancake_net_transport_inproc.h` | `pancake_inproc_*` plus its own last-error pair                                                                                                                                                            |
| `libpancake_net_transport_iroh`   | `pancake_net_transport_iroh.h`   | `pancake_iroh_*` (links a Rust sidecar)                                                                                                                                                                                           |

Each archive exports only its own `pancake_<family>_*` symbols and carries
its own last-error reader; `libpancake_ocapn` owns the shared C-visible
types and return codes, so every consumer links it as the universal base.
There is no umbrella archive and no catch-all header, and a transport
archive shares no runtime symbol with the peer, cooperating only through
the `PancakeContext` the consumer creates and through type layout
(ADR-0055, ADR-0059). The ABI is versioned: `pancake_abi_version` reports
what the linked library implements so header/library skew is detectable,
and since the major version is still 0, symbols and layouts can still
change.

Allocation policy travels as a context rather than a bare allocator. A
`PancakeContext` owns the allocator for a family of handles, either the
library's own or host-bound `alloc`/`free` callbacks, and everything a
context-scoped handle allocates frees back through that same context
(ADR-0031). A Zig `std.mem.Allocator`, a slice, an error union, or a
`std.Io` object never crosses the C ABI; only plain C callbacks bound to a
context do. The blocking TCP endpoint handles follow that contract exactly,
reading a whole frame, feeding it to the peer, and writing outbound frames
back, and `pancake_last_error` re-surfaces the concrete socket cause behind
a flat `PANCAKE_ERR_IO` (ADR-0030).

## Examples As Contract

Examples are not snippets; they are build targets. The numbered chapters
under `examples/zig/` walk CapTP from the application surface down to the
raw engine, and [`examples/README.md`](../examples/README.md) indexes them.
The lower-level mechanics have build targets of their own too:

- `examples/zig/frame_view.zig` proves the Zig library surface can express
  owned frame transfer and borrowed views directly.
- `examples/c/frame_view.c` proves `pancake_ocapn.h` is ordinary C ABI
  vocabulary by linking an exported symbol from `libpancake_ocapn`.
- `examples/c/context_alloc.c` proves a C embedder can own every pancake
  allocation, driving a `PancakeContext` from host callbacks over a bump
  arena and asserting the frees balance the allocations.
- `examples/c/echo_peer.c` links `libpancake_ocapn` and
  `libpancake_net_transport_tcp` together, the à-la-carte composition a TCP
  consumer uses.
- `examples/c/compose_transports.c` links `libpancake_ocapn` with both the
  tcp and inproc transport archives into one binary, standing proof that
  the archives compose without a symbol collision (ADR-0059).

`zig build check` runs every example.
