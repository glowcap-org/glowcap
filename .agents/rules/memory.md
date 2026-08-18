---
description: "Zig pancake memory and frame ownership: owned transfer, bounded borrow, explicit test-only copies."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h
---

# pancake — Memory and Frame Ownership

## A copy is a design event

Every allocation or copy on the wire path is **forbidden, named, or measured**,
and forbidding is the default verdict. Naming one is a decision you have to
earn: re-derive it against the _full_ option set, not the binary the copy first
presents. A copy is not "copy versus retain the whole source" when one durable
owner can hold the value; a shim is not "shim versus break the world" when the
world is yours to change ([prerelease](prerelease.md) — there is no migration
to pay).

Cross-surface consistency is part of that derivation: a negligible cost off
the wire path, paid so sibling fronts keep one contract, earns its name more
easily than a micro-saving earns an asymmetry.

The ledger at the end of this rule is the list of copies that survived that
derivation. Each entry names the contract that requires it and what deleting it
would cost. **Do not "optimize" one away without re-deriving its contract**, and
do not add one without earning a place beside them.

If a caller cannot tell whether an API transfers, borrows, or copies, the API is
wrong.

## Frame contract

- `Frame` owns wire bytes; `FrameView` borrows them for a bounded call.
- `FrameShape.byte` means ordinary byte storage.
- `FrameShape.word` means word-aligned storage: pointer aligned to 8, byte
  length divisible by 8.
- Allocation alignment is tracked separately from `shape`, so a byte frame may
  be over-aligned and still free with its true allocation metadata.

## Ownership verbs

- `Frame.initOwned` adopts storage without copying. `Frame.view` borrows without
  allocating.
- `Peer.send(Message)` takes ownership and moves the message into the outbound
  queue. This is the canonical, copy-free path.
- `Peer.sendCopying(Message)` names the one boundary copy over `send`, for
  callers holding borrowed or static message data they keep owning.
- `Peer.feedOwned(Frame)` transfers ownership for queued dispatch, consuming the
  frame on every outcome. `Peer.recvBorrowed(FrameView)` dispatches during the
  call and retains no wire borrow.
- `engine.pipeline.decomposeOutboundDeliver` repartitions a multi-hop pipelined
  deliver by _moving_ each path step's payload into its own message, freeing only
  the emptied `path.ops` backing slice. It copies no payload. The one allocation
  is the `[]Message` chain container, and the drain side allocates no container
  at all: a drained pipelined call whose target resolved to _another_ promise
  moves one message at a time into `Session.requeuePipelinedCall`, which appends
  it directly and frees it on refusal.
- `Peer.emitAbortForError` handles an inbound refusal, including the inbound
  dispatch arm of `step`, by committing a fresh outbound `op:abort` through
  `Peer.commitAbortOutbound`, bypassing `recordSend`, because a session being
  refused always admits its abort. Deferred local work and outbound encoding
  propagate pressure without calling it: the same `OutboundBackpressure` name
  means a partner-owned cap only at the inbound boundary. The diagnostic is a
  static `[]const u8` borrowed by encode, so there is no message clone. The path
  retains an encode or append failure as `AbortInfo.abort_delivery_error` while
  returning the original dispatch error, and the session still closes when the
  projection requires it, even with no queued frame. Host admission reserves
  the resulting flush notification, so publishing that embedder effect is
  infallible after the session exists. Cleanup consequences retain their first
  name and bounded count in `AbortInfo.secondary_error`; its saturation test
  and the `Peer` size gate keep that diagnosis inside already-paid padding.
- Test-support copy helpers (`test/support/frame.zig`, for example
  `copyFromBorrowed`) materialize borrowed wire bytes for assertions. **Copy
  helpers belong in `test/support`, never in a production module.**

## Allocator discipline

- The owner that allocates releases. Store enough metadata to free correctly;
  word storage must be freed with word alignment.
- Never hide allocation behind a neutral API name.
- Do not add `unsafe` as an optimization shortcut. Escalate first.
- A map removal whose key presence is an established invariant asserts it:
  `std.debug.assert(map.remove(k))` still runs the remove in release and only
  adds the check in safe builds. Only a genuinely idempotent ensure-absent
  removal discards the bool, and then it carries an inline `// idempotent:` or
  `// tolerant:` justification. `source-check` holds this for every
  `_ = <map>.remove(` / `.fetchRemove(` / `.swapRemove(` in `src/`.

## Footprint budgets that bite

The 500k-connection destination is gated by the build (ADR-0045), so **a field
added to session state is a withdrawal from it**. When a gate below trips, weigh
the bytes and raise the budget deliberately, in the constant and in
`docs/ladder.md` step 2 together. Never route around the check.

| Gate | Holds |
| --- | --- |
| `@sizeOf(Peer)` comptime (`peer_session_struct_budget_bytes`, 1136) | one session's struct |
| `test/engine/footprint_budget_test.zig` | a warmed session's core state at or under 2 KiB |
| `@sizeOf(Conn) - @sizeOf(engine.Peer)` comptime in `src/net/completion/loop.zig` | the loop wrapper's own bookkeeping at exactly `conn_slot_overhead_bytes` (128). An equality, so a field added to `Conn` fails the build rather than spending headroom nobody is watching |
| `CompletionBackend.connection_state_bytes` / `secure_connection_state_bytes` in `test/net/keyed_relay_completion*_test.zig` | the completion-backed keyed-relay adapter state at exactly 248 bytes for a clear leg; WSS alone adds a sparse 37,216-byte TLS state including its two fixed 18 KiB record windows. Clear legs pay none of it. Mask entropy belongs to the single-owner backend RNG, not a 520-byte CSPRNG copied into every connection |
| `@sizeOf(HostSession)` comptime in `src/driver/core/host.zig` | the byte-fed host shell. The Host session ceiling is 528 bytes (ADR-0107's sealed-channel pointer is the last eight); narrower targets may be smaller. The Host owns one shared Vat, so the 448-byte Vat is charged once per Host rather than per session, and a `Peer` lives behind a pointer |
| `test/actors/vat_footprint_budget_test.zig` | a burst-then-quiescent Vat back under the arena and one-spare bounds |
| `test/engine/deliver_set_scratch_budget_test.zig` | a big-set frame's recv scratch under its bound |

Retained capacity is bounded per owner, so a burst cannot pin its peak for the
connection's life:

- The engine's four peer queues each bound retained backing at
  `steady_queue_bytes = 4096` (`src/ocapn/engine/mod.zig`), freeing burst
  capacity at the drain for the named price of one growth re-allocation when the
  next burst begins.
- `Session.recv_scratch` keeps only `steady_recv_scratch_bytes = 384`
  (`src/ocapn/session/mod.zig`, beside the field). It is far smaller than the
  queues' bound because the session answers to the 2 KiB core-state budget and
  its arena must leave room for the tables beside it, while one admissible frame
  can grow the arena to several times `max_frame_bytes` in owned `Argument`s.
- The actor layer holds the same posture at Vat scale
  (`src/actors/vat/mod.zig`): `steady_turn_arena_bytes` and
  `steady_settle_arena_bytes` bound the two long-lived arenas at 4096,
  `steady_spare_arena_bytes` (4096) bounds the one Vat-wide spare queue chunk,
  and `steady_list_bytes` (4096) bounds the `moved_replies` list and sets the
  fixed queue-row target. An empty ingress retains no chunk at all, and the
  allocation budget proves a warmed local queue batch performs zero
  general-purpose allocations.

## The ledger

Every allocation and copy that survived the derivation above, one line each.

**The full derivation lives at the declaration, not here.** Each entry names the
symbol that owns the cost, and that symbol's doc comment carries the argument:
the hazard, the lifetime, and what breaks if the copy is deleted. Read it before
touching the site. This list exists so nothing is unnamed and so a reviewer can
see the whole budget at once; duplicating each argument here would give one fact
two authorities that drift apart. `source-check` holds every symbol below to a
declaration under `src/`, so a rename breaks the entry instead of quietly
pointing it at nothing.

### Wire path: session and engine

- **Outbound boundary copy** — `Peer.sendCopying` into `model.cloneMessage`. The
  one named copy over `send`, for drivers holding borrowed, fixed-array, or
  static input against an owning queue. Deleting it scatters the same dupes into
  every driver, one per hand-written locator and key copy.
- **Owned inbound frame** — `ownedFrameFromView` in `Peer.recvBorrowed`. The
  **only** allocation a steady-state deliver to a live export costs, and the
  irreducible wire-path floor `test/engine/alloc_budget_test.zig` asserts.
- **Recv scratch arena** — `Session.recv_scratch`. The common inbound kinds
  validate and apply straight from the borrowed `model.view.Body` with zero
  materialization; only the two paths that _retain_ (a pipelined deliver queued
  on its answer, and the substructure-heavy `gc_*` kinds) build an owned
  `Message`, as turn scratch that dies in the `retain_with_limit` reset every
  recv entry point runs. Handoff is an argument arm on the borrowed walk;
  `get`/`index`/`untag` stay borrowed too. Apply dupes anything session-lived
  onto the gpa, so the reset can never dangle a table row. Send-side folds stay
  on the gpa, because no recv turn brackets a send.
- **Introduced-import record** — `validate.IntroducedImports`. One walk serves
  validate and apply; allocation-free for the common no-reference message, and
  depth-bounded by `SessionLimits.max_nesting_depth` so a nested argument tree
  fails loud instead of overflowing the stack.
- **Introduced-import event patch** — `Event.introduced_far_imports`
  (`engine/inbound.zig`). One gpa dupe per reference-introducing deliver, because
  the event outlives the turn record. The dupe is acquired before authority
  applies; OOM refuses the transaction instead of changing the event's
  bookkeeping shape after commit.
- **Set-uniqueness compare budget** — `checkInboundSetUniqueness`,
  `SessionLimits.max_compare_visits`. Borrowed elements hash and compare as
  views, so nothing materializes, but two sets compare as multisets and a
  partner can construct an equal-hashed pair deliberately. Every visit charges
  the turn's allowance and exhaustion refuses `CompareBudgetExhausted`. On Syrup
  this re-verifies what decode refused: one named redundant walk, kept so the
  invariant is codec-neutral rather than a per-codec trust.
- **Sent-resolve store** — `Session.applySentResolve`. The resolution _moves_
  into the answer row (a consume contract) and the encoder reads it back through
  `peekResolution`, which is what makes a move safe where a borrow would dangle.
  Zero copies, pinned by `test/engine/resolve_alloc_budget_test.zig`.
- **Listener fire carriers** — `engine.Outbound.listener_fire`,
  `Session.store_stamp_counter`. POD carriers over the stored resolution or a
  live export's near fulfill; zero payload copies. Queue-time retains pin the
  payload's `near` exports across the queue-to-encode window against a legal
  partner `op:gc-exports`, which is why fire accounting cannot move to encode
  time. Row identity stamps make a released-and-reused position leave the fire
  moot rather than shipping another row's payload. Pinned by
  `test/engine/listener_fire_budget_test.zig`.
- **Outbound byte accounting** — `Peer.queuedOutboundBytes`. One machine word
  per peer, updated where the outbound queue takes or transfers frame ownership,
  so a byte-fed host's backpressure check is O(1) instead of re-walking every
  queued frame before each feed or serve call. At 500,000 sessions the fixed
  charge is about 4 MiB; the peer struct and warmed-state checks hold it.
- **Relayed resolution** — `Peer.applyRelayedResolution`,
  `Session.recordRelayedResolution`. Lower in place (this path bypasses `send`'s
  chokepoint), move into the store, fire from the store. Written exactly once, so
  a second relay is refused. A terminal Node relay that cannot prepare listener
  carriers commits the store and increments one `u32` retry count on the Peer;
  only while nonzero does `step` scan imported-promise rows for stored values
  with listeners. No clone anywhere on the single-store path; held by behavior
  tests rather than a budget test.
- **Proxy fan-out** — `Node.proxyForeignPromiseFulfill`,
  `Node.stageInlinePassable`. One home `op:listen` is shared across recipients,
  never N listens. The Host lifts the fire once; each recipient owns one bounded
  materialization because its references, gives, and promise positions differ.
  Admission owns one fixed terminal-break buffer and action seat per recipient,
  so projection, signing, entropy, or teardown failure cannot strand it.
  Object occurrences mint one recipient-addressed give each; promise
  occurrences share the existing home-listener machinery. Bounded by
  `Node.max_proxy_recipients` and the recipient queue cap.
- **Inline Passable projection staging** — `Node.stageOutbound`,
  `Peer.reserveInlinePassableStaging`. One complete owned message waits outside
  the ordinary outbound queue while object projections receive gift ids and
  promise projections prepare their shared home listener plus recipient
  escrows. No partial rewrite, exporter deposit, proxy listener, or recipient
  import becomes visible. Its measured model bytes remain charged to the
  recipient's ordinary outbound waterline, total staged capability occurrences
  remain under that session's queue cap, and every same-exporter deposit is
  admitted as one cumulative batch. The message moves into the ordinary queue
  at commit; it is never cloned a second time.
- **Projection anchors** — `Peer.respondToProjection`. One dupe of the field name
  or tag, because the projection outlives the view that carried it. `op:index`
  dupes nothing. Bounded per answer by `max_listeners_per_target` (ADR-0050).
- **Local-delivery frame synthesis** — `Peer.deliverDrainedCallLocally`. One
  synthesized frame, which the frame-based event model requires: a borrowed frame
  cannot carry a message that never arrived on the wire. Bounded by
  `max_local_deliveries`; named, not measured.
- **Partner location and key arena** — the `start_session` arm of
  `session/apply.zig`, into `Session.key_arena`. Session tables are authoritative
  and outlive any frame, so the partner's session key and location bytes are
  duped in. When decode supplies verbatim location bytes, **that one buffer is
  the sole owner and the designator is a relocated subslice of it**, not a second
  dupe; owned-apply has no raw bytes and keeps a designator-only dupe. Every
  byte-keyed table is O(1) rather than a `std.mem.eql` scan. **A bump arena is
  the right owner only because those tables never remove a row**, which is why
  the FIFO-evicting `sturdyref_cache` and the individually-removed
  `pending_enlivens` keep their bytes on the gpa instead.
- **Resolver-export link** — `Session.outbound_resolver_link`. One POD row per
  live listen (ADR-0095), no owned bytes.
- **Shortening GC closure** — `expandGcExportReleases`. Rare outbound-GC
  scratch plus replacement position/delta slices keep edge-owned import retains
  in the same validated wire operation; ordinary sends allocate nothing here.
- **Sturdyref enliven dedup** — `Session.notePendingEnliven` (ADR-0012). One
  swissnum dupe per in-flight row, moved into the resolved cache on fulfillment.
  A full resolved cache evicts before insertion; an in-flight row reserves both
  cache structures before committing the fetch, so allocation failure refuses
  the enliven transaction rather than silently disabling dedup.
- **Freed export ranges** — `engine.Node.freed_export_bases`. Export ranges are a
  fixed budget, so a released session's range comes back and is re-handed
  oldest-first. Registration reserves the exact future return slot before the
  range becomes session authority, making release infallible under allocator
  pressure; no layer above keeps a session's base.
- **Canonical set and struct ordering** — `writeCanonicalSet`,
  `writeCanonicalStruct`, `writeHintDict`, `encodeArgumentSetList`. Encode each
  element once and sort the encodings, turn scratch freed before encode returns.
  **Sorting on model values instead lets two encoders disagree; the bytes are the
  only order both sides reproduce.**
- **Boxed handoff argument** — the handoff arm of `view.zig`'s
  `Argument.toOwned`. Boxed so the largest arm does not set the size of _every_
  `Argument`; `src/ocapn/model/mod.zig` asserts 40 bytes for `Argument` and 48
  for `Resolution` at comptime, so un-boxing fails the build.
- **Crypto fixed-width materialization** — `crypto.PeerKey.fromSlice`,
  `crypto.Signature.fromParts`. `std.crypto` takes fixed arrays and offers no
  allocator pattern; the wire has slices.
- **Give-location dialable form** — `handoff_gifter.dialableExporterLocation`.
  One decode-and-re-encode per give whose *onion* exporter hello carried
  `pancake/*` profile hints and whose recipient is not known to be pancake
  (ADR-0118); every other give — every non-onion transport, every Goblins
  exporter — takes the null path allocation-free and embeds the verbatim
  hello bytes its receiver's withdrawal keying matches. The derivation lives
  at the declaration.
- **Handoff canonicalization** — one owned signing-domain buffer per certificate.
  An immediate withdrawal never owns the inbound tree. A Syrup-forwarded give
  carries its exact signed envelope, so receive bypasses typed hints; Cap'n
  Proto's lazy hints project into bounded scratch freed before return.
- **Gift registry** — `engine.bootstrap.GiftRegistry`. Per-`Peer` rows on the gpa
  with precise frees, **never a bump arena**, which cannot reclaim an overwritten
  row and would leak every re-deposit. The outbound message is built and queued
  before an infallible commit removes the gift, so queue OOM leaves it
  retryable. **Because a consumed row is gone, the row count _is_ the live-gift
  count**, so `max_deposited_gifts` needs no parallel counter.
- **Swissnum miss diagnostic** — `resolveForSwissnum` (`engine/bootstrap.zig`).
  One string dupe on the unknown-name break path, because the diagnostic must
  outlive the resolving frame and `send` frees the resolution it rides in. The
  fulfill arm is POD and allocates nothing.
- **Parked withdraw** — `Peer.pending_withdraws` (ADR-0100). One compact verified
  claim per early `withdraw-gift`, retaining neither signature, exporter locator,
  receiving names, nor signed envelope. Bounded by `max_pending_withdraws` and
  the session's `max_frame_bytes`. Refusing the early withdraw instead would
  break the deposit-may-arrive-second contract the upstream suite pins.
- **Handoff coordination** — `Node.handoff_waiters`. Scheduler state, never
  authority. **The fixed-size 128-bit BLAKE3 gift tag is what keeps an
  attacker-selected gift-id length out of coordination state**; signed bytes stay
  the authority, so a collision costs one bounded retry. Deposit and close
  notification allocate nothing after the first group.
- **Redeem dial parts** — `Node.stagePendingDial`. Parse the exporter URI once
  into identity and dial parts, keep no verbatim URI, and carry only the ticket
  in `Node.Action.dial` / `HostAction.dial`. An unparseable locator fails closed
  with no staged heap. **No re-parse anywhere on the redeem dial path.**

### Actor layer

- **Ingress clone** — `Vat.send` / `Vat.tell`'s local arm, over
  `model.cloneArgumentSlice`. `sendCopying`'s contract inside one vat: a queued
  turn runs at a later `drive` whose first outermost turn resets the very arena
  the handler built its args in. `model.measureArgumentSliceOwnedBytes` walks the
  same shape first, so admission refuses a limit **before any queue mutation**.
- **Settle clones** — `Vat.settle_arena`. Each defends two hazards, which is why
  it can be re-homed but never deleted: a listener may open a top-level turn
  whose depth-0 reset frees a turn-arena value mid-call, and the value may borrow
  the settling actor's own state, which a listener-run turn can mutate or
  `become`-free. Depth-guarded, so it covers a nested drive and a far listener
  re-entering `serve` through a driver pump.
- **Far send verb splice** — `farDeliverTo`. Stack buffer to seven args, then one
  immediately-freed gpa spine — **never the turn arena, because the path is
  callable at depth 0**, where a bump pins until the next outermost turn.
- **Reply sever on install** — `callLocal`. Clones the reply onto the turn arena
  when a `become` will install at this frame's unwind, because the install frees
  the box the reply may borrow. **The gate is the install, not this frame's own
  staging.** An ordinary near-call still returns its reply borrowed, and `serve`
  needs no clone at all, because it copies onto the wire inside the turn window.
- **Moved replies** — `Turn.moveOut` / `moveOutString`, `Vat.moved_replies`. A
  handler that owns its reply's bytes _transfers_ them instead of paying the
  sever, and `callLocal` skips the sever only on pointer identity with that
  turn's own moves, so a reply borrowing any other state is still severed.
- **State boxes** — `StateBox`, `releaseBox`, `ensureUnshared` (ADR-0060). One
  refcounted heap block per actor, so `Vat.snapshot` shares boxes at zero bytes
  copied and a non-snapshotting actor pays one pointer indirection. Deleting the
  layer forces an eager O(total-mutable-bytes) snapshot copy.
- **Retired boxes** — `Vat.retired_boxes`. A `become` install swaps the cell's
  box but its reference falls at the next outermost turn, because an _earlier_
  frame of the same actor may already have returned a reply borrowing it, leaving
  no live frame to copy it. Registration escrows one pointer slot per live actor
  so last-root release and teardown never allocate; `stageBecome` additionally
  reserves one slot per open frame, not per stage. Burst backing is replaced
  transactionally at the next outer-turn boundary, while the live-actor escrow
  remains.
- **Turn-forward context** — `Vat.forwardTurn`. One gpa `ForwardContext` per
  forwarded turn that answers the wire, freed when its listener fires or swept by
  `freeOwnedForwardContexts`.
- **Actor roots** — one `u32` per row (ADR-0101). Each relationship holds one
  root, transferred at the seam that owns it; root zero retires the row past any
  running frame and parks the box on the retirement capacity registration
  escrowed before the actor became visible.
- **Persistent map nodes** — `persistent.PersistentMap` (ADR-0061). O(log n)
  fresh nodes per write with refcounted structural sharing; an immutable trie is
  acyclic, so the count frees with no collector, and retains happen only after
  every allocation in a rebuild succeeds. Rebuilding whole makes `become`
  O(size).

### Transports, loops, and streams

- **Inbound spill** — `foundation.Spill` (ADR-0041). Where stream bytes wait
  before they make a whole frame. **It is bytes and nothing else, which is what
  lets `net` and `driver_core` share it** when neither can import the other, and
  each tier names only what a drained spill keeps. Deleting it relocates the cost
  into `max_frame_bytes`-sized per-connection read buffers.
- **Byte-fed stream tail** — `HostSession.feed_tail` via `Host.feedBytes`. The
  one owner of the tail four binding pumps each kept by hand. Zero copies with no
  pending tail; one bounded coalesce per chunk while one is pending. Straddling a
  chunk is ordinary here rather than exceptional, so this tier retains
  `steady_feed_tail_bytes` instead of freeing outright.
- **Sealed byte channel** — `foundation.sealed.SealedChannel` (ADR-0107), one
  channel type with one thin owner per stream tier: the byte-fed `HostSession`
  boxes one per sealed session (the unsealed shell pays one null pointer), and
  the loop tier's sealing completion adapter (`net.noise_completion`) embeds
  one in its per-connection state. The channel stages inbound wire in its own
  spill, bounded by one record plus a chunk tail, and opens each record into a
  plaintext scratch shrunk back to steady size by the next small record.
  Sealing and opening pay the one AEAD pass per record ADR-0107 names;
  `sealFrame` allocates one owned wire frame per outbound frame, `sealBytes`
  seals a stream chunk into a caller-owned queue, and `takeWire` dupes the
  fixed-size pending handshake message. Deleting the box moves key material
  onto every shell in the 500k budget; deleting the record copy means
  encrypting over borrowed frame bytes the engine still owns.
- **Sealing adapter ciphertext staging** — the sealed dial arm of
  `net.noise_completion` (ADR-0107). The loop's submitted send is a borrow,
  and record boundaries survive partial inner writes only if the ciphertext is
  owned, so sealed records and handshake messages stage in a two-buffer queue:
  the frozen half is borrowed by the wrapped backend until its send completes
  while fresh seals append to the open half — the loop's own ADR-0042 shape,
  one tier down. A drained burst retains at most the steady bound; opened
  record plaintext is lent to the recv seat zero-copy from the channel's own
  scratch, safe because the loop holds one recv seat per connection and
  recycles before re-arming. Per-leg state is pinned exactly by
  `test/net/noise_relay_test.zig`; unsealed connections pay nothing.
- **Shared read-buffer pool** — `completion.BackendOptions.read_buffers` ×
  `completion.BackendOptions.read_buffer_bytes` (ADR-0054). An idle
  connection holds zero read-buffer bytes; whole frames apply zero-copy from the
  pool view and a partial tail pays one bounded copy into the spill. **The
  zero-copy claim is scoped to spill-inactive.** Deleting the pool reopens the
  per-connection buffer floor, about 7.6 GiB at 500k; deleting the tail copy
  means parsing across recycled storage.
- **Outbound queue front and back** — `completion.Loop` (ADR-0042). One copy in,
  because the loop cannot block on a send. **Two buffers because a submitted
  write borrows `front` while the loop keeps running**, and appending could
  realloc that storage out from under the kernel. Steady retention is
  per-buffer, so the ceiling is 32 KiB per connection, not 16. Bounded by read
  backpressure at `completion.Options.outbound_high_water_bytes`, whose
  independent 64 KiB default is replaceable without changing admission or pool
  sizing.
- **Completion-adapter transport staging** — iroh `enqueue_outbound` and
  keyed-relay `queueFrame` (ADRs 0057 and 0088). The Loop's submitted send is
  a borrow, while both foreign async engines must own bytes past the call: iroh
  copies the admitted prefix into one queue whose queued plus in-flight bytes
  share `NB_BUFFER_BOUND`; keyed-relay keeps the external write borrowed through
  its one completion and copies and masks one bounded WebSocket chunk at a time
  into `RelayConn.ws_out`, as RFC 6455 requires. The unsent tail is a subslice of
  the Loop-owned borrow, including while a Pong owns the wrapped send seat: a
  second whole-write copy is forbidden.
  Iroh retains at most one `NB_STEADY_BYTES` spare after a drained burst; relay
  send staging retains at most `RelayOptions.send_staging_bytes`, 4 KiB by
  default including the frame header. A larger override is an explicit
  per-connection memory commitment, not a frame-admission limit. WSS copies
  ciphertext once into its fixed TLS record window and writes decrypted bytes
  directly into that same WebSocket staging path; refused TLS sends retry from
  allocation-free intrusive links in bounded turns, never by cloning the
  application payload or adding a per-connection thread.
- **iroh provider connection-id table** — `LoopAdapter`
  (`src/c_abi/net_transport/iroh/mod.zig`, ADR-0112). One POD row per live
  loop connection, mapping the sidecar's stable id to its handle, because
  drained records carry ids while the sidecar verbs take handles. Rows enter
  at `finish_connect`, free precisely at `conn_close`, and netlayer release
  sweeps stragglers; no byte payload crosses the table.
- **Keyed-relay configuration and carrier lease** — `keyed_relay.Resident`
  copies both URLs into one block because parsed `RelayUrl` fields are retained
  views. One heap `carrier_runtime.Lease` state owns I/O per resident; each
  listener and admitted channel retains one pointer-sized lease, making the
  last release follow their close barriers. There is no per-dial config copy.
- **Keyed-relay receive projection** — the completion adapter lends ordinary
  WebSocket payload directly from the wrapped backend's shared recv buffer,
  preserving its token so recycle returns to the actual owner. Only a split
  header or control frame, upgrade residue, or the next-frame tail coalesced
  behind a payload crosses into `RelayConn.raw_in`. A platform receive that
  completes after its caller seat was canceled also copies there so stream
  bytes survive recycling the shared buffer; a replacement seat installed
  before completion still takes the ordinary zero-copy path. The spill is
  hard-bounded to one platform buffer plus the parser prefix, and capacity
  above `steady_raw_in_bytes` is released when drained. The blocking resident
  still copies from its socket reader into the caller's CapTP reader.
- **WebRTC C-facing staging** — one bounded inbound deque and one bounded
  outbound staging buffer per peer (ADR-0089), because the C ABI exposes
  synchronous reads and nonblocking try-writes while the `webrtc` 0.20 data
  channel is async. The inbound poller admits a message only when the whole
  message fits under `INBOUND_BUFFER_BOUND`, and it refuses a single message
  larger than that budget. Try-writes copy into the outbound staging buffer and
  return without entering the runtime; an async drain task sends bounded chunks
  through `DataChannel::send`. The crate's SCTP receive window and send buffer
  are separately bounded at the same layer. Readiness is endpoint-owned, and its
  self-pipe writes distinguish sent, safely coalesced, and failed outcomes.
  `WouldBlock` alone is coalesced success because unread bytes already make the
  fd readable; every other write or drain fault is latched by the owning
  runtime and settles or terminalizes its admitted work.
- **WebRTC signaling transfer** — `SignalPayloadPool` in the native completion
  backend. `provideAnswer` and `provideRemoteCandidate` are callable from
  foreign threads, while a caller-supplied Zig allocator may be single-threaded.
  The backend therefore allocates one fixed 4 MiB endpoint-level pool on its
  owner thread and copies each bounded signaling payload into an exclusive slot
  before publishing the queue row. The loop returns the slot after applying the
  row; no foreign thread enters the allocator, no payload allocation reaches the
  session byte path, and overload is `WouldBlock` rather than heap growth.
- **Browser WebRTC candidate staging** — `RtcPeer` snapshots the standard ICE
  fields before retaining a remote candidate, caps one candidate at 4 Ki text
  units, and caps each pre-SDP or apply queue at 256 candidates / 64 Ki text
  units. Local candidates waiting for a signaling sink carry the same bounds.
  Once a sink is installed, `SignalingSendOwner` admits at most 256 unresolved
  signaling sends and aborts bring-up on overflow. The rooms carrier creates
  one row per active dial before gathering starts, holds early local candidates
  behind the directory's admitted exchange id, expires routing rows after 30
  seconds, and retires that exact id when bring-up ends. These queues are
  signaling control state, not session bytes, but remain attacker-influenced
  when the signaling capability crosses a network.
- **Pinned stream wrapper** — `net.tcp`'s `TcpStream`, and `IrohStream`
  (ADR-0043, ADR-0055). `std.Io.Reader`'s vtable recovers its concrete reader
  from `&interface` by field offset, so the reader and writer need a stable
  address outside the by-value `Connection`. Storing them inline dangles the
  moment the connection moves. Blocking path only; the loop builds no
  `Connection`.
- **Bridge slots** — `driver.Bridge.Slot` and its ConnId-to-slot map (ADR-0076).
  One shell per adopted connection. The map row is removed **first thing** in
  `freeConnCtx`, before the release's drain, so a teardown drain can arm sibling
  slots but never the dead one. Peers are never bridge-owned.

### Host tier

- **Host face wires** — `driver.HostRuntime`'s `Wire` (ADR-0090, ADR-0112). One
  shell per session plus two `wire_buffer_bytes` buffers on a stream link, one
  on a multiplexed-provider link, freed only by its owner. Protocol admission
  stays independently bounded by `frame_cap`: a larger frame assembles in the
  core's bounded spill instead of making every live wire retain the maximum.
  A multiplexed-provider link may also retain one outbound frame across a full
  write window — owned transfer from `takeOutbound`, resumed at its offset on
  `ev_writable`, never a copy. An EOF marks the wire closed and breaks its vows
  **without freeing**, because a view still holds the pointers: the
  close-and-release split. Poll scratch grows once and then allocates nothing.
- **Pending open rows** — `HostRuntime.startDial`,
  `HostRuntime.startAcceptWire`, and the redeem drain into
  `HostRuntime.stageDial` (ADR-0112). One gpa row per in-flight dial or
  accept, carrying stage, deadline, and outcome route; no byte payload because
  the locator is consumed at stage time. The shared `max_pending_opens`
  admission bound limits these rows and their pre-open sessions/wires across
  every route; blocking dial and accept consume the same counter while they
  pump without owning a row. Rows are heap-owned and removed before their
  settle notification runs, since a notification may stage further dials and
  a list realloc must not move a row mid-sweep.
- **Lower and lift boundary** — `driver.Session` (ADR-0096). Per-verb scratch
  arena on the way down (spines only; leaves stay borrowed) and the caller's
  arena on the way up, with capability rows under rollback receipts. **The lift
  aliases the settle capture rather than re-cloning, which is why `Reply` is
  arena-only and carries no `deinit`.**
- **Settle capture** — one `model.cloneArgument` or broken-reason dupe per
  blocking wait (`BlockingSession.call`, `driver.Promise.settle`, `SettleCapture`).
  Severs the turn-borrowed resolution so the returned `Settled` outlives the
  drive. `fetch` and `enliven` stay allocation-free.
- **Unobserved vow completion** — `driver_core` host `queueCompletion`. One deep
  clone per settle with no in-process listener, **moved, never re-cloned**, into
  whoever drains it, because the embedder reads it after `feed` returns. The
  drain-side re-clone was re-derived against the full option set and deleted: the
  popped action is a transient carrier and the parked table is the durable owner.
  **The fire cannot strand** — every mint reserves its queue slot, so the
  infallible append never fails, and the FIFO keeps its reservation peak until
  teardown because a drain must not revoke promised capacity.
- **Settle mailbox** — `driver.SettleMailbox` (ADR-0102). Fixed slots at init, so
  a worker's `post` allocates nothing; one boundary clone into the slot's arena,
  refusing `ValueTooLarge` and `MailboxFull`. Backpressure, never growth.
- **Loop-archive dial and events** — `pancake_driver_dial`,
  `pancake_driver_next_event` (ADR-0112). A dial projects the borrowed locator
  only for its call and starts the provider immediately; the nonblocking
  provider contract lets the loop retain no locator copy. Admission reserves
  one event slot per externally observed open, so OPENED, OPEN_FAILED, and
  ACCEPTED callbacks append without allocation; error names are static. A
  completion action is the one owned event payload — moved from the drain
  through the completion sink, never re-cloned, projected with the byte-fed
  queue's own scratch and freed through `Host.freeAction`. Session events carry
  a peer id beside the pointer, so release invalidates them in O(1) and drain
  skips stale rows without touching freed memory. Sink and close-observer
  appends remain best-effort under allocation failure, named at their
  declarations.
- **Host session indexes** — `Host.partner_by_side`, `dialed_by_designator`
  (ADR-0012). O(1) dial and partner-key refusal at the 500k tier, on the gpa with
  precise frees, because rows leave individually.
- **Session close timing** — `Host.session_close_timing` (ADR-0114). One gpa map
  row per finite-grace session close, removed at `Host.markSessionTerminating`
  or tolerantly at `freeSessionShell`. Cancel and unbounded finishes pay
  nothing, so an open session stores no deadline; the timing lives out of line
  for exactly that reason, argued at the declaration.
- **Host session locator identity** — `Host.mintShell` (ADR-0098). One owned block
  holding the transport (and, for a dial, the selected designator), because the
  sturdyref peer check needs the actual session transport and a signed locator
  cannot supply it. Replaces a block the dial already required, so it adds
  nothing.
- **Import identity memo** — `session.ImportTable.identities`. **Both identities
  must die with the import row**, because a partner may reuse a released position
  and a surviving memo would revive the previous object. The row also counts
  surfaced retains, so one borrowed reference cannot be lifted repeatedly into
  matching GC authority. Behind one pointer and null until needed.
- **Host capability registry** — `driver_core.capability.Registry` (ADR-0096).
  Three indexes so a repeated lift reuses one id, a stale or foreign id is
  rejected, and session close scans only capabilities homed there. Six
  allocations on a first remote lift, zero on a repeat or a lower; 80 bytes per
  slot and 24 per identity row by comptime budget. Ids never come back: a
  process-keyed 64-bit permutation over one monotonic source. Projection records
  each lift so a later failure rolls the partial projection back with an exact
  wire GC release, eight receipts on the stack before spilling.

### Named deferred costs

Named where they are, not forbidden. Relocating one does not delete it, so the
name stays here.

- **Bridge app-dial dupes** — `OutboundConnect.app_dial` owns transport and
  designator for the connect window, because adoption needs them and the loop
  retains only the resolved target. Redeem stays ticket-only and re-borrows
  `pendingDial`; it must not take this cost.
- **Binding dial OS-connect string** — each binding decodes `host` and
  `addresses` once after `pancake_host_plan_dial`, because the OS connect API
  needs a language string. A second rematerialize of the same view through
  `readMemory` / `string_at` / `bytes<-c` is forbidden.
- **Binding outbound flush copy** — TypeScript, Python, and Racket copy
  managed-frame bytes and release before the async write; Rust holds the frame
  across it. Language and lifetime forced: no change without a hold-across-await
  proof.
- **TypeScript native-connection write copy** — `AsyncFfiWriteQueue` snapshots a
  caller-owned frame before off-thread TCP, inproc, or onion FFI can borrow it.
  No single frame or admitted set may cross the connection's frame-scale byte
  waterline; later writes are refused until ownership retires, and a separate
  16-write cap keeps zero-length calls from retaining an unbounded promise
  chain.
- **Racket inbound `pin-immobile`** — every `feed_bytes` path pins the buffer
  into collector-immobile memory first. The tail lives in the core session, so no
  binding-side coalesce rides on top.
- **Wasm linear-memory boundary** — `bindings/ts/web/adapter.ts` (ADR-0070).
  JavaScript cannot lend wasm a view, so every buffer argument pays one copy in
  and each `outBuffers`-marked out-parameter one copy back. **Do not delete the
  memoized re-stage's resync as an optimization**; staged copies retire two
  outermost-call windows later, because a call's returned views alias its staged
  inputs.
