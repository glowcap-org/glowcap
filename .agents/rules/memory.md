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
- `Peer.emitAbortForError` handles an inbound refusal or a `step` drain failure
  by committing a fresh outbound `op:abort` through `Peer.commitAbortOutbound`,
  bypassing `recordSend`, because a session being refused always admits its
  abort. The diagnostic is a static `[]const u8` borrowed by encode, so there is
  no message clone. The path is best-effort: an encode or append failure is
  swallowed so it cannot mask the original dispatch error, and the session still
  closes when the projection requires it, even with no queued frame.
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
  `// tolerant:` justification. `meta-check` holds this for every
  `_ = <map>.remove(` / `.fetchRemove(` / `.swapRemove(` in `src/`.

## Footprint budgets that bite

The 500k-connection destination is gated by the build (ADR-0045), so **a field
added to session state is a withdrawal from it**. When a gate below trips, weigh
the bytes and raise the budget deliberately, in the constant and in
`docs/ladder.md` step 2 together. Never route around the check.

| Gate | Holds |
| --- | --- |
| `@sizeOf(Peer)` comptime (`peer_session_struct_budget_bytes`, 1112) | one session's struct |
| `test/engine/footprint_budget_test.zig` | a warmed session's core state at or under 2 KiB |
| `@sizeOf(Conn) - @sizeOf(engine.Peer)` comptime in `src/net/completion/loop.zig` | the loop wrapper's own bookkeeping at exactly `conn_slot_overhead_bytes` (128). An equality, so a field added to `Conn` fails the build rather than spending headroom nobody is watching |
| `@sizeOf(HostSession)` comptime in `src/driver/core/host.zig` | the byte-fed host shell. The Host session ceiling is 496 bytes; narrower targets may be smaller. The Host owns one shared Vat, so the 448-byte Vat is charged once per Host rather than per connection, and a `Peer` lives behind a pointer |
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
two authorities that drift apart. `meta-check` holds every symbol below to a
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
  on its answer, and the substructure-heavy `gc_*` / `handoff` /
  `get`-`index`-`untag` kinds) build an owned `Message`, as turn scratch that
  dies in the `retain_with_limit` reset every recv entry point runs. Apply dupes
  anything session-lived onto the gpa, so the reset can never dangle a table
  row. Send-side folds stay on the gpa, because no recv turn brackets a send.
- **Introduced-import record** — `validate.IntroducedImports`. One walk serves
  validate and apply; allocation-free for the common no-reference message, and
  depth-bounded by `SessionLimits.max_nesting_depth` so a nested argument tree
  fails loud instead of overflowing the stack.
- **Introduced-import event patch** — `Event.introduced_far_imports`
  (`engine/inbound.zig`). One gpa dupe per reference-introducing deliver, because
  the event outlives the turn record. Best-effort by contract: apply has already
  committed, so an OOM leaves the field null and `gc` walks for itself.
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
- **Relayed resolution** — `Peer.applyRelayedResolution`,
  `Session.recordRelayedResolution`. Lower in place (this path bypasses `send`'s
  chokepoint), move into the store, fire from the store. Written exactly once, so
  a second relay is refused. No clone anywhere on the single-store path; held by
  behavior tests rather than a budget test.
- **Proxy fan-out** — `Node.proxyForeignPromiseFulfill`,
  `materializeResolutionForStore`. One home `op:listen` per home wire shared
  across recipients, never N listens; N=1 moves, above that each recipient store
  materializes. A bare far object takes the handoff arm
  (`Node.giftRelayedCapability`) at one give per recipient, because a give is
  signed for one recipient's session key. Bounded by
  `Node.max_proxy_recipients`.
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
  Non-load-bearing: an overflow evicts and a failed insert is swallowed, because
  a miss costs one bootstrap-fetch round-trip, not correctness.
- **Freed export ranges** — `engine.Node.freed_export_bases`. Export ranges are a
  fixed budget, so a released session's range comes back and is re-handed
  oldest-first. The draw and the return sit on the same side of the boundary,
  which is why no layer above keeps a session's base. Best-effort: the release
  path has nowhere to report OOM, and a lost range costs one slot in a million.
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
  no live frame to copy it. `stageBecome` reserves one slot per open frame, not
  per stage. What the list holds is one outermost turn's installs, so a handler
  looping over a becoming actor retains one box per iteration.
- **Turn-forward context** — `Vat.forwardTurn`. One gpa `ForwardContext` per
  forwarded turn that answers the wire, freed when its listener fires or swept by
  `freeOwnedForwardContexts`.
- **Actor roots** — one `u32` per row (ADR-0101). Each relationship holds one
  root, transferred at the seam that owns it; root zero retires the row past any
  running frame and parks the box on the retired list. On reservation failure the
  row stays: a bounded leak, never a dangling box.
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
- **Shared read-buffer pool** — `Options.read_buffers` (ADR-0054). An idle
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
  backpressure at `Options.outbound_high_water`. The iroh `Backend` holds the
  same posture over one buffer, throttling the partner through QUIC flow control
  (ADR-0057).
- **WebRTC callback bridge** — one bounded inbound deque and one bounded outbound
  batch per peer (ADR-0089), because `webrtc` 0.14 delivers through a serialized
  callback rather than a borrowed read. Checking the bound before the callback
  parks limits overshoot to one message and lets SCTP throttle the partner.
  Readiness is endpoint-owned, and its self-pipe writes are best-effort **under
  one invariant**: `WouldBlock` means the pipe already holds unread bytes, so the
  fd is already readable and no wake was lost.
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

- **Host face wires** — `driver.PollHost`'s `Wire` (ADR-0090). One shell plus two
  `frame_cap` buffers per session, freed only by its owner. An EOF marks the wire
  closed and breaks its vows **without freeing**, because a view still holds the
  pointers: the close-and-release split. Poll scratch grows once and then
  allocates nothing.
- **Lower and lift boundary** — `driver.Session` (ADR-0096). Per-verb scratch
  arena on the way down (spines only; leaves stay borrowed) and the caller's
  arena on the way up, with capability rows under rollback receipts. **The lift
  aliases the settle capture rather than re-cloning, which is why `Reply` is
  arena-only and carries no `deinit`.**
- **Settle capture** — one `model.cloneArgument` or broken-reason dupe per
  blocking wait (`BlockingSession.call`, `Session.settleVow`, `SettleCapture`).
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
- **Host session indexes** — `Host.partner_by_side`, `dialed_by_designator`
  (ADR-0012). O(1) dial and partner-key refusal at the 500k tier, on the gpa with
  precise frees, because rows leave individually.
- **Host connection identity** — `Host.mintShell` (ADR-0098). One owned block
  holding the transport (and, for a dial, the selected designator), because the
  sturdyref peer check needs the actual connection transport and a signed locator
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
- **Racket inbound `pin-immobile`** — every `feed_bytes` path pins the buffer
  into collector-immobile memory first. The tail lives in the core session, so no
  binding-side coalesce rides on top.
- **Wasm linear-memory boundary** — `bindings/ts/web/adapter.ts` (ADR-0070).
  JavaScript cannot lend wasm a view, so every buffer argument pays one copy in
  and each `outBuffers`-marked out-parameter one copy back. **Do not delete the
  memoized re-stage's resync as an optimization**; staged copies retire two
  outermost-call windows later, because a call's returned views alias its staged
  inputs.
