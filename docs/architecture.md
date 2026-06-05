# pancake Architecture

pancake is a library-shaped OCapN / CapTP core. It is designed so protocol
correctness, wire compatibility, ownership, allocation, and host integration
costs are visible in the API that creates them.

## Founding Thesis

```text
protocol semantics: fixed, correct, interoperable
implementation overhead: aggressively minimized
```

Performance is part of the correctness contract. Every allocation and every copy
on the wire path is either forbidden, intentional, or measured.

Project setup follows the same contract: build steps should be obvious,
examples should compile, public artifacts should be named for `pancake`, and no
tooling layer should hide ownership, allocation, I/O, scheduling, or authority.

## Protocol Oracle, Zig Shape

OCapN behavior, Spritely Goblins wire fixtures, and pancake's checked protocol
scenarios are the conformance gates. Zig expresses those boundaries directly;
Rust dogfood is consumer proof for the C ABI, not the semantic authority.

Core invariants:

- Codec-neutral semantics.
- Authoritative session state.
- A sync, no-I/O canonical runtime.
- Explicit frame ownership and borrowed message views.
- C ABI ownership promises.
- Conformance fixtures and scenario traces as release gates.
- Dogfooding before compatibility claims.

The Zig repo keeps a local oracle bridge under `test/oracle/` and
`test/oracles/`. It enumerates the shipped message model, embeds the Goblins
Syrup fixture corpus, and defines the session-trace shape used by runtime
scenario tests.

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

Adapters feed inbound frames, call `Peer.step`, drain outbound frames, and poll
events. Adapters may use `std.Io`, native transports, or host callbacks, but
they do not add CapTP behavior.

## Netlayer (`net_adapter`)

The netlayer is the one place `std.Io` enters; the arch gate
(`tools/arch_check.zig`) keeps it out of the five core layers and admits
`net_adapter` as a non-core layer imported only by `c_abi` and the public root.

- **One parser (ADR-0029).** Stream frame boundaries are found by the active
  codec's own decoder (`codec.dispatch.decodePrefix`), which distinguishes
  `incomplete` (read more), `decoded` (whole frame + consumed length),
  `malformed`, and `too_large`. The runtime consumes that single verdict in
  `Peer.recvStreamPrefix`; there is no separate length-prefix or delimiter
  scanner. A deeply nested untrusted prefix is rejected at decode time
  (`max_decode_nesting`) before it can overflow the stack.
- **Connection (ADR-0030).** `net_adapter.Connection.pumpOver` folds that parser
  over a type-erased `std.Io.Reader`/`Writer` — encode + flush outbound, apply
  one inbound frame zero-copy, distinguish graceful EOF from a mid-frame
  truncation — so the framing core is proven with `Reader.fixed`/`Writer.fixed`
  without a socket. `net_adapter.tcp` is the only `std.Io.net`-to-socket site;
  `net_adapter.FrameStream` is the peer-less frame seam the C ABI sits on.
- **Bounded per-connection memory (ADR-0030).** Inbound frame size is capped by
  `SessionLimits.max_frame_bytes` (`too_large` → `resource_exhausted` abort).
  The small-buffer/bounded-overflow path, full-duplex backpressure, and
  crossed-hellos are deferred by name in ADR-0030.

## Session Representation

The session is authoritative state, and its interior is data-oriented: the
protocol hands out dense, monotonically-allocated integer positions
(`next_export_id++`, `next_outbound_answer++`, partner-allocated import/answer
positions), so the session spends those positions as keys instead of
re-deriving them with linear scans.

- **Position-keyed tables.** Exports, imports, and inbound/outbound answers are
  O(1) position-keyed maps (`SlotTable` for the wire-delta refcounts,
  `AnswerTable` for answers), not linearly-scanned lists. GC validation is a
  single pass with O(1) per-position lookup.
- **Hot/cold answers.** An answer row is the hot state-machine fields (status +
  refcount); its pipelining payload (queued calls, listeners, stored resolution)
  hangs off a pointer allocated only when an answer actually accrues one. The
  public accessor returns a by-value `AnswerView`.
- **Byte-keyed tables are hashed.** `bootstrap`, `gifts`, and `handoff_counts`
  are `StringHashMap`s whose key bytes live in one per-session byte arena (one
  free at teardown); the FIFO-evicting `sturdyref_cache` and the
  individually-removed `pending_enlivens` / imported-promise hosts keep precise
  per-row ownership, because a bump arena cannot reclaim an evicted row.
- **Borrowed-validate / owned-on-retain.** The steady-state inbound path
  validates and applies authority straight from the borrowed codec projection;
  an owned message is materialized only when a deliver must be queued for
  pipelining (the one path that retains), and the rare sub-structure-heavy kinds
  (`gc_*`, `handoff`, `get`/`index`) materialize one transient copy into a
  per-turn scratch arena reset wholesale at the end of the turn. A steady-state
  deliver to a live export costs exactly one allocation — the owned-frame copy
  the event model requires — asserted by `test/runtime/alloc_budget_test.zig`.
- **Forward-cursor argument walks.** The borrowed `Args` / `PositionList` /
  `PipelinePath` sequences expose a forward `iterator()` whose `next()` advances
  a codec-interpreted cursor, so the validate / install / materialize walks make
  one linear pass. Random-access `at(i)` re-scans a byte-framed list from the
  start, so a loop of `at(i)` is O(n^2) with a per-element indirect call; the
  iterator is the shape the hot paths use.
- **Bounded recursion (resilience).** The recursive argument-tree walks are
  depth-bounded by `SessionLimits.max_nesting_depth`, so an attacker-nested
  inbound frame fails loud (`NestingTooDeep` → `resource_exhausted` abort)
  instead of overflowing the native stack (ADR-0028). `view.toOwned` and
  `model.argumentsEqual` carry an independent fixed ceiling as a model-layer
  backstop.
- **Structural state gate.** Inbound and outbound dispatch run an exhaustive
  `switch (session.state)` admission gate (`admitInState`) at the dispatch head,
  so a new state variant cannot silently inherit "admit everything"; the
  per-message validators hold only kind-specific rules.
- **Float64 equality is `Object.is`, not IEEE `==`** (ADR-0027): every NaN is
  Equal to every other NaN and `+0.0` is distinct from `-0.0`, the
  Pass-Invariant-Equality axis Model.md requires.

### ADR — bare-position keys, no generational handles

pancake allocates its *own* positions monotonically — `next_export_id++`,
`next_outbound_answer++` — and never reuses them, so a position it issues is a
stable key for the life of the session. A *partner* is not bound by that policy:
the CapTP spec lets a peer reuse an `answer-pos` once it has been GC'd ("provided
the answer position is not in use, it is a valid answer position";
[`op:gc-answers`] — "the `answer-pos` can be re-used"), and import positions are
likewise partner-named. The slot tables still need no generational handle or ABA
guard, but the reason is *not* "positions are never reused" — it is that every
position-keyed row is removed at GC (the answer row and its queued calls,
listeners, and resolver links die together in `decrementAnswer`). A partner's
permitted reuse therefore lands on a cleared table, indistinguishable from a
fresh position; there is no stale dependent state for a recycled id to collide
with, so a bare position is a sufficient key.

The tables are integer-keyed hashes (not raw `position -> slot` vectors) because
those partner-allocated positions are attacker-influenced: a hostile peer naming
a sparse `import_id` would size a flat backing store to that index — a memory DoS
the resilience caps exist to prevent. The hash keeps the O(1) lookup without that
footgun. (pancake's own export / outbound-answer namespaces are dense and could
use a flat vector safely; the tables are uniformly hashed for one contract across
trusted and partner-named positions rather than splitting the representation.)

## Memory Contract

`Frame` owns wire bytes. `FrameView` borrows wire bytes for a bounded call scope.
Default frame movement is either ownership transfer (`Frame`) or bounded borrow
(`FrameView`). Session state must not retain borrowed wire memory.

The correct decode split is:

- `decodeView`: project a borrowed semantic view over frame bytes;
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
- `MemoryEndpoint.writeFrameOwned` transfers an owned `Frame` into the endpoint
  without copying.
- `test/support/memory_endpoint.zig` may inject a borrowed-copy frame into a
  `MemoryEndpoint` for tests. Production `MemoryEndpoint` has no borrowed-copy
  writer.

The target shape is explicit: inbound C ABI borrowed frames dispatch
synchronously, inbound C ABI managed frames transfer into a peer-owned queued
frame without copying, runtime-owned frames move by transfer, events return the
originating frame in the negotiated codec without re-encoding, and outbound C ABI
returns a managed frame with a release callback. Zig must preserve that contract
and make accidental copies harder to write.

## C ABI Contract

The C ABI stays boring:

- opaque handles;
- fixed-width integer discriminants;
- `ptr + len` byte views;
- explicit release functions;
- callbacks with caller context;
- clear return codes.

Public artifacts are named for the project: `libpancake.a`, `libpancake.so`,
and `pancake.h`.

Zig slices, allocators, error unions, futures, and `std.Io` objects do not cross
the C ABI. The blocking `tcp-testing-only` endpoint handles
(`pancake_endpoint_tcp_*`) keep this contract: a host that owns the peer shuttles
whole frames (`read_frame -> feed_owned -> step -> take_outbound ->
write_frame`). Because `std.Io` cannot cross the boundary, the I/O backend is an
explicit owned handle (`PancakeTcpNetlayer` owns one `std.Io.Threaded`, created
and freed by the host) rather than a hidden global runtime, and
`pancake_last_error` re-surfaces the concrete socket cause behind a flat
`PANCAKE_ERR_IO` (ADR-0030).

## Examples As Contract

Examples are not snippets. They are build targets:

- `examples/zig/frame_view.zig` proves the Zig library surface can express owned
  frame transfer and borrowed views directly.
- `examples/c/frame_view.c` proves `pancake.h` is ordinary C ABI vocabulary and
  links an exported symbol from `libpancake`.

`zig build check` runs both examples.

