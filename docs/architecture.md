# pancake Architecture

pancake is an OCapN / CapTP core you use as a library. The guiding idea is
simple: the things that usually hide — whether a frame is owned or borrowed,
where a copy or an allocation happens, which wire format is in play, where I/O
and scheduling live — should all be visible right at the API that creates them.

## Design Contract

```text
protocol semantics: fixed, correct, interoperable
implementation overhead: aggressively minimized
```

Performance is part of the correctness contract. Every allocation and every copy
on the wire path is either forbidden, intentional, or measured.

Project setup follows the same contract: build steps should be obvious, examples
should compile, public artifacts should be named for `pancake`, and no tooling
layer should hide ownership, allocation, I/O, scheduling, or authority.

## Protocol Oracle, Zig Shape

OCapN behavior, Spritely Goblins wire fixtures, and pancake's checked protocol
scenarios are the conformance gates. Zig expresses those boundaries directly;
Rust dogfood is consumer proof for the C ABI, not the semantic authority.

Core invariants:

- Semantics are codec-neutral.
- Session state is authoritative.
- The canonical engine is sync and does no I/O.
- Frame ownership is explicit, and message views are borrowed.
- The C ABI keeps its ownership promises.
- Conformance fixtures and scenario traces gate every release.
- Dogfooding comes before compatibility claims.

The Zig repo keeps a local oracle bridge under `test/oracle/`. It enumerates
the shipped message model, embeds the
pancake-authored Syrup fixture corpus under `test/oracle/corpus/` (byte vectors
cross-checked through the
upstream Syrup encoders, not Goblins captures, see
[`test/oracle/README.md`](../test/oracle/README.md)), and defines the
session-trace shape used by engine scenario tests. Goblins-canonical wire
authority comes from the live Goblins peer under `conformance/goblins-peer/` and
the upstream conformance suite, not from this corpus.

Out of the core:

- runtime-specific I/O structure;
- package-manager-shaped topology;
- wrapper layers that hide ownership, allocation, or authority decisions.

## Core Boundary

The canonical core owns protocol semantics and nothing else:

- no sockets;
- no `std.Io`;
- no background tasks;
- no hidden scheduler;
- no process-level runtime object.

This is why the driving layer is named `engine`, not `runtime`. A runtime is the
ambient executor with its own scheduler and tasks that the core refuses to be;
the engine is the caller-driven alternative, dispatching a session synchronously
and nothing more.

The layering itself is compiler-enforced: each `src/` layer is an internal
build.zig module with a one-way import table (ADR-0040), so a cross-layer reach
is a compile error rather than a convention to remember. The same law runs one
level deeper inside the codec layer: each sibling wire codec is its own module
over the shared `framing` verdict module, so Syrup and Cap'n Proto cannot import
each other, and only the codec root (`dispatch`, `registry`) knows both
(ADR-0048). The four layers that _are_ the OCapN / CapTP protocol — `model`,
`codec`, `session`, `engine` — live together under `src/ocapn/` and are reached
as `pancake.ocapn.<layer>`, so the tree and the public namespace both say which
layers are the protocol and which are built on top of it (ADR-0044).
`src/root.zig` curates the one public `pancake` namespace over those modules.

Adapters feed inbound frames, call `Peer.step`, drain outbound frames, and poll
events. Adapters may use `std.Io`, native transports, or host callbacks, but
they do not add CapTP behavior.

## Netlayer (`net`)

The netlayer is the one place `std.Io` enters; the arch gate
(`tools/arch_check.zig`) keeps it out of every core layer — `foundation`,
`model`, the codec stack (`framing`, `syrup`, `capnp`, and the `codec` root),
`session`, `engine`, `actors`, and `persistent` — and the build.zig layer module
tables (ADR-0040) are what admit `net` as a non-core module imported by `c_abi`,
the `driver` layer, and the public root.

- **One parser (ADR-0029).** Stream frame boundaries are found by the active
  codec's own decoder (`codec.dispatch.decodePrefix`), which distinguishes
  `incomplete` (read more), `decoded` (whole frame + consumed length),
  `malformed`, and `too_large`. The engine consumes that single verdict in
  `Peer.recvStreamPrefix`; there is no separate length-prefix or delimiter
  scanner. A deeply nested untrusted prefix is rejected at decode time
  (`max_decode_nesting`) before it can overflow the stack.
- **Connection (ADR-0030, ADR-0043).** `net.Connection.pumpOver` folds that
  parser over a type-erased `std.Io.Reader` and `std.Io.Writer`. One pump cycle
  encodes and flushes outbound frames, applies one inbound frame without a
  second parse, and distinguishes graceful EOF from a mid-frame truncation. The
  framing core is tested with `Reader.fixed` and `Writer.fixed`, so it is proven
  without a socket. `Connection` is transport-generic: it borrows the reader and
  writer interfaces, and it closes the underlying stream through a
  `TransportHandle`. Any transport that yields those std.Io interfaces can drive
  it. `net.tcp` is the only `std.Io.net`-to-socket site. `net.FrameStream` is
  the peer-less frame boundary the C ABI sits on.
- **Netlayer contract (ADR-0043).** A transport is a runtime resident, not a
  privileged built-in. `net.netlayer.Netlayer` is a vtable that dials a locator
  to a `Connection` and binds a `Listener`. The driver's `connectVia` and
  `acceptVia` resolve the locator's transport symbol against a caller-owned
  `[]const net.netlayer.Netlayer` slice through `net.netlayer.resolve`, and they
  fail closed on an unknown symbol. The contract has three residents. tcp is the
  first, through `net.tcp.Resident`. The in-process switchboard `net.inproc` is
  the second (ADR-0047): it wires a dialer and a listener through in-process
  byte pipes, with no sockets at all, so a full OCapN conversation can run
  inside one process. The iroh QUIC netlayer is the third, through the resident
  in `src/net/transport/iroh.zig` (ADR-0055). The inproc and iroh residents each
  registered without an edit to the driver or the core: a new transport is a new
  resident, not a new privilege. The completion loop stays outside this contract,
  an fd-based option a raw-fd transport may offer beside the netlayer API, not a
  capability every netlayer must satisfy.
- **Bounded per-connection memory (ADR-0030, ADR-0041, ADR-0042).** Inbound
  frame size is capped by `SessionLimits.max_frame_bytes`, so an oversized frame
  is refused as `too_large` and projected to a `resource_exhausted` abort. The
  read buffer sizes the steady state, not the largest admissible frame. A frame
  that outgrows the buffer accumulates once in `net.Spill`, the bounded owned
  spill shared by the pump, the peer-less frame reader, and the completion loop.
  The spill is freed as soon as it drains, so per-connection memory does not
  scale with the cap. On the completion loop the read buffers themselves are a
  shared backend-owned pool (ADR-0054), so an idle connection holds no
  read-buffer memory at all. The completion loop bounds outbound memory the same
  way. When pending reply bytes cross a high-water mark, that connection's reads
  are parked until the partner drains the queue, and burst capacity is freed on
  drain. The blocking pump stays a single fiber by contract: it serves
  cooperative request/response, and a partner that streams without draining
  belongs on the completion loop (ADR-0053). Crossed hellos sits one layer
  higher: `driver.crossed_hellos` holds the tiebreak registry, and
  `driver.Host` owns it — a dial registers the outbound before bytes move,
  accepted connections compare inbound start-sessions against it, and the
  engine only projects the typed abort (ADR-0068).

## Actors and local time-travel (`actors`, `persistent`)

The `actors` layer owns opt-in local time-travel: a `Vat` can `snapshot`
its local actor heap and `restore` it, sharing each actor's state behind a
non-atomic refcounted box (O(objects), no byte copy), with copy-on-write for
mutable actors and functional `become` for persistent ones (ADR-0060). It is
local-only, a snapshot never captures session state and a restore never rewinds
a peer. The sibling `persistent` leaf supplies one refcounted-HAMT
`PersistentMap` (ADR-0061) so a persistent actor's incremental `become` is O(log
n) with structural sharing; it imports nothing and is not on the public
namespace.

## Application surface (`driver`)

The `driver` layer sits above both the actor turn loop and the netlayer, the one
place that may touch `std.Io` and the actor vat at once.

`driver.ConnectedVat` binds an `actors.Vat` to a live `net.Connection` over one
caller-owned `engine.Peer`, sparing a networked app the hand-written open, pump,
and dispatch loop. It hides nothing: every read and write is one explicit
`ConnectedVat.step`, and a host that answers until the partner leaves calls
`ConnectedVat.serve`.

The one-object face above it is the owning `driver.Connection`. `driver.connect`
dials and `driver.listen` hosts, each `accept` handing back a connection; each
connection owns its peer and buffers, and one `frame_cap` sizes the buffers and
the session's frame limit together. `Connection.call` blocks until the reply
settles and returns the outcome into a caller-supplied arena: fulfilled, broken,
or a `.give`, the typed introduction a three-party handoff delivers.

`driver.Host` is the multi-connection tier every binding builds inside its own
`connect` (ADR-0068): one identity, one `engine.Node`, many node-registered
connections. `Host.redeem` runs the serve step's recipient half in one blocking
call, a served reply that returns a foreign-homed capability originates a give
through the vat's resolve interceptor, and `call`/`send` route redeemed tokens to
the connection that hosts them.

Below these are the explicit-ownership escapes. `connectTcp` and `acceptTcp` hand
the caller the allocator, buffers, and peer directly, both naming tcp at the
constructor; `ConnectedVat.over` wraps a `Connection` the caller already holds
over any stream; and `LoopHost` and `LoopDialer` package accepted hosting and
outbound fan-out above the completion loop. All keep actor policy in `driver`,
leaving `net` only fd readiness and peer I/O. A consumer who outgrows the whole
surface reaches the raw peer through `ConnectedVat.peer`.

## Session Representation

The session is authoritative state, and its interior is data-oriented: the
protocol hands out dense, monotonically-allocated integer positions
(`next_export_position++`, `next_outbound_answer++`, partner-allocated
import/answer positions), so the session spends those positions as keys instead
of re-deriving them with linear scans.

- **Position-keyed tables.** Exports, imports, and inbound/outbound answers are
  O(1) position-keyed maps, not linearly-scanned lists. Exports and imports
  share one wire-delta refcount core (`SlotTable`) but wrap it in distinct
  `ExportTable` and `ImportTable` types, so the cap that bounds partner-driven
  imports is a property of `ImportTable` rather than a check each call site must
  restate; answers use `AnswerTable`. GC validation is a single pass with O(1)
  per-position lookup.
- **Hot/cold answers.** An answer row is the hot state-machine fields (status +
  refcount); its pipelining payload (queued calls, listeners, projections,
  stored resolution) hangs off a pointer allocated only when an answer actually
  accrues one. The public accessor returns a by-value `AnswerView`.
- **Byte-keyed tables are hashed.** The session's `bootstrap` registry is a
  `StringHashMap` whose key bytes live in one per-session byte arena (one free
  at teardown); the FIFO-evicting `sturdyref_cache` and the individually-removed
  `pending_enlivens` / imported-promise hosts keep precise per-row ownership,
  because a bump arena cannot reclaim an evicted row. The handoff `gifts` and
  `handoff_counts` tables are vat-scoped, not per-session: they live in
  `engine.bootstrap.GiftRegistry` (ADR-0056) with precise per-row frees, because
  a re-deposit replaces a row.
- **Borrowed validation, owned only when retained.** The steady-state inbound
  path validates and applies authority straight from the borrowed codec
  projection. An owned message is materialized only when a deliver must be
  queued for pipelining, because that is the path that retains the message. The
  rare sub-structure-heavy kinds, such as `gc_*`, `handoff`, `get`, and `index`,
  materialize one transient copy into a per-turn scratch arena that is reset at
  the end of the turn. A steady-state deliver to a live export costs exactly one
  allocation: the owned-frame copy required by the event model. That budget is
  asserted by `test/engine/alloc_budget_test.zig`.
- **Forward-cursor argument walks.** The borrowed `Args` / `PositionList` /
  `PipelinePath` sequences expose a forward `iterator()` whose `next()` advances
  a codec-interpreted cursor, so the validate / install / materialize walks make
  one linear pass. Random-access `at(i)` re-scans a byte-framed list from the
  start, so a loop of `at(i)` is O(n^2) with a per-element indirect call; the
  iterator is the shape the hot paths use.
- **Bounded recursion (resilience).** Recursive argument-tree walks are bounded
  by `SessionLimits.max_nesting_depth`. An attacker-nested inbound frame
  therefore fails loudly instead of overflowing the native stack. The walk
  raises `NestingTooDeep`, which projects to a `resource_exhausted` abort
  (ADR-0025). `view.toOwned` and `model.argumentsEqual` carry an independent
  fixed ceiling as a model-layer backstop.
- **Structural state gate.** Inbound and outbound dispatch run an exhaustive
  `switch (session.state)` admission gate (`admitInState`) at the dispatch head,
  so a new state variant cannot silently inherit "admit everything"; the
  per-message validators hold only kind-specific rules.
- **Float64 equality is `Object.is`, not IEEE `==`** (ADR-0021): every NaN is
  Equal to every other NaN and `+0.0` is distinct from `-0.0`, the
  Pass-Invariant-Equality axis Model.md requires.

### Bare-position keys, no generational handles

pancake allocates its _own_ positions monotonically — `next_export_position++`,
`next_outbound_answer++` — and never reuses them, so a position it issues is a
stable key for the life of the session. A _partner_ is not bound by that policy:
the CapTP spec lets a peer reuse an `answer-pos` once it has been GC'd
("provided the answer position is not in use, it is a valid answer position";
`op:gc-answers` — "the `answer-pos` can be re-used"), and import positions are
likewise partner-named. The slot tables still need no generational handle or ABA
guard, but the reason is _not_ "positions are never reused": it is that every
position-keyed row is removed at GC (the answer row and its queued calls,
listeners, and resolver links die together in `decrementAnswer`). A partner's
permitted reuse therefore lands on a cleared table, indistinguishable from a
fresh position; there is no stale dependent state for a recycled id to collide
with, so a bare position is a sufficient key.

The tables are integer-keyed hashes rather than raw position-to-slot vectors
because partner-allocated positions are attacker-influenced. A hostile peer
could name a sparse `import_position` and force a flat backing store to grow to
that index. The hash keeps O(1) lookup without that memory denial-of-service
risk. pancake's own export and outbound-answer namespaces are dense enough for
flat vectors, but the tables use one hashed representation for both trusted and
partner-named positions.

## Memory Contract

`Frame` owns wire bytes. `FrameView` borrows wire bytes for a bounded call
scope. Default frame movement is either ownership transfer (`Frame`) or bounded
borrow (`FrameView`). Session state must not retain borrowed wire memory.

The correct decode split is:

- `decodeBody`: project a borrowed semantic view over frame bytes;
- `decodeOwned`: materialize an owned semantic value only when persistence,
  tests, debugging, or cross-boundary ownership require it.

`FrameShape` distinguishes byte storage from word-aligned storage (the `word`
shape is 8-byte-aligned storage with a byte length divisible by 8). Syrup is
byte-framed; Cap'n Proto is word-framed. A codec-neutral core keeps that shape
distinction explicit at the frame boundary instead of flattening every frame to
generic bytes.

## Copy Budget

Copies must be named at the boundary where they occur. They are not the default
frame movement model:

- `Frame.initOwned` adopts an already-owned allocation without copying. Callers
  pass the allocation alignment explicitly so `Frame.deinit` frees with the same
  metadata used to allocate.
- `Frame.initExternal` adopts externally managed storage without copying and
  invokes the supplied release hook on `Frame.deinit`.
- `test/support/frame.zig` may copy caller bytes into frame-owned allocations
  for tests and fixtures. Production `Frame` has no copy constructor.
- `Frame.view` must not allocate or copy.
- `Peer.sendCopying` names its queueing cost at the API boundary.
- `Peer.recvBorrowed` retains the transient borrowed wire bytes with a single
  named copy; `Peer.feedInbound` / `Peer.step` move an already-owned frame into
  the surfaced event with zero copies.
- A surfaced `Event` retains the originating frame in the negotiated codec.
  `Event.view` projects it without allocating; `Event.decodeOwned` materializes
  an owned model only on demand. The C ABI returns those exact bytes without
  decoding and re-encoding, so the event surface stays codec-neutral.
- `MemoryEndpoint` is test support (`test/support/memory_endpoint.zig`), not a
  production layer. Its `writeFrameOwned` transfers an owned `Frame` into the
  endpoint without copying — the same owned-transfer seam `net` fills over a
  real stream — and its borrowed-copy injector exists only for tests.

The target shape is explicit: inbound C ABI borrowed frames dispatch
synchronously, inbound C ABI managed frames transfer into a peer-owned queued
frame without copying, engine-owned frames move by transfer, events return the
originating frame in the negotiated codec without re-encoding, and outbound C
ABI returns a managed frame with a release callback. Zig must preserve that
contract and make accidental copies harder to write.

## C ABI Contract

The C ABI stays boring:

- opaque handles;
- fixed-width integer discriminants;
- `ptr + len` byte views;
- explicit release functions;
- callbacks with caller context;
- clear return codes.

The C ABI ships as a set of composable per-family archives, linked à la carte,
rather than one umbrella library (ADR-0059). A consumer links the protocol it
needs and the transports it chooses, and the pieces compose the way a C program
that includes two headers and links two archives composes:

| Archive                           | Header                           | Exported family                                                                                                                                                                                                                   |
| --------------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `libpancake_ocapn`                | `pancake_ocapn.h`                | the sans-io peer plus the shared vocabulary: `pancake_abi_version`, `pancake_context_*`, `pancake_peer_*`, `pancake_uri_*` / `pancake_locator_*`, the frame/event releases, and `pancake_last_error` / `pancake_clear_last_error` |
| `libpancake_net`                  | —                                | net-core base; exports nothing under the shipping mechanism (Model A), so it adds no symbol but holds its place in the link recipe                                                                                                |
| `libpancake_net_transport_tcp`    | `pancake_net_transport_tcp.h`    | `pancake_tcp_*` plus its own `pancake_tcp_last_error` / `_clear`                                                                                                                                                                  |
| `libpancake_net_transport_inproc` | `pancake_net_transport_inproc.h` | `pancake_inproc_*` plus its own `pancake_inproc_last_error` / `_clear`                                                                                                                                                            |
| `libpancake_net_transport_iroh`   | `pancake_net_transport_iroh.h`   | `pancake_iroh_*` (links a Rust sidecar)                                                                                                                                                                                           |

Each archive ships in both static (`.a`) and shared (`.so`) form, exports only
its own `pancake_<family>_*` symbols, and carries its own last-error reader.
`libpancake_ocapn` owns the shared vocabulary — the C-visible types, return
codes, and codec selector — and is the universal base every consumer links; each
transport header `#include`s `pancake_ocapn.h` to share those types by layout.
There is no umbrella archive and no catch-all header, no "everything" artifact
(ADR-0059). A transport archive shares no runtime symbol
with the peer: it cooperates only through the `PancakeContext` the consumer
creates and through type layout, so the archives stay symbol-disjoint and link
together without collision (ADR-0055, ADR-0059).

The ABI is versioned. `pancake_ocapn.h` carries `PANCAKE_VERSION_*` macros for
the version the headers were compiled against. `pancake_abi_version` reports the
version the linked library implements, so header and library skew is detectable.
Each shared archive carries a soname tracking the major version, currently `.0`.
The major version is 0, so the ABI is unstable: symbols, layouts, and return
codes can still change.

Allocation policy is a context. A `PancakeContext` owns the allocator for a
family of handles. `pancake_context_new` uses the library-owned allocator, and
`pancake_context_new_with_allocator` binds host `alloc` and `free` callbacks.
The `*_in` constructors, such as `pancake_peer_new_in` and
`pancake_tcp_netlayer_new_in`, allocate from a context. Every allocation made by
a context-scoped handle frees back through that context: handle objects, managed
outbound and event frames, adopted inbound frames, and TCP connection/listener
payloads with their buffers. The context must outlive its handles. In a
host-backed context, the allocator vtable lives inside the context object, and
the context object itself is allocated through the host callbacks, so the whole
handle family follows host policy. Callers still free handles only through the
explicit release functions. The context is allocation policy, not a `free` a
caller invokes by hand (ADR-0031).

A Zig `std.mem.Allocator`, slices, error unions, futures, and `std.Io` objects
do not cross the C ABI. Allocation policy crosses as plain C callbacks bound by
a context, never as a Zig allocator. The blocking TCP endpoint handles
(`pancake_tcp_*` — cleartext, no TLS) keep this contract. A host that owns the
peer reads a whole frame, feeds the owned frame to the peer, steps the peer,
takes outbound frames, and writes them back. Because `std.Io` cannot cross the
boundary, the I/O backend is an explicit owned handle rather than a hidden
global runtime: `PancakeTcpNetlayer` owns one `std.Io.Threaded`, created and
released by the host. `pancake_last_error` re-surfaces the concrete socket cause
behind a flat `PANCAKE_ERR_IO` (ADR-0030).

## Examples As Contract

Examples are not snippets. They are build targets. The numbered chapters under
`examples/zig/` are the CapTP walkthrough, reading from the application surface
down to the raw engine, and [`examples/README.md`](../examples/README.md)
indexes them. The lower-level mechanics have build targets too:

- `examples/zig/frame_view.zig` proves the Zig library surface can express owned
  frame transfer and borrowed views directly.
- `examples/c/frame_view.c` proves `pancake_ocapn.h` is ordinary C ABI
  vocabulary and links an exported symbol from `libpancake_ocapn`.
- `examples/c/context_alloc.c` proves a C embedder can own every pancake
  allocation: it drives a `PancakeContext` from host `alloc`/`free` callbacks
  over a bump arena, creates a peer in it, and asserts the frees balance the
  allocations.
- `examples/c/echo_peer.c` links `libpancake_ocapn` and
  `libpancake_net_transport_tcp` together, the à-la-carte composition a TCP
  consumer uses.
- `examples/c/compose_transports.c` includes `pancake_ocapn.h`,
  `pancake_net_transport_tcp.h`, and `pancake_net_transport_inproc.h` and links
  all three archives into one binary. It is the standing proof that the archives
  compose without a duplicate-symbol collision and that each family resolves
  (ADR-0059).

`zig build check` runs every example.
