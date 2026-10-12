---
name: memory-ledger
description: "Use when adding, deleting, moving, or renaming an allocation or copy on the wire path, or a symbol a ledger entry names: the inventory of every named cost and the declaration that owns its derivation."
---

# glowcap — Memory Ledger

The [memory rule](../../rules/memory.md) says when a wire-path allocation or
copy may exist: forbidden by default, named only after a full derivation,
measured when deleted. This file inventories the named costs.

## The ledger

Each entry names a cost and its owning symbol. The declaration's doc comment
holds the hazard, lifetime, and consequence of removal, so read it before
editing the site. `source-check` verifies that every named symbol has a
declaration under `src/`.

### Wire path: session and engine

- **URI rendering**: `uri.writeOwned`. One exact-size allocation shared by peer and
  sturdyref emission, including handoff dial routes. Validation and sizing
  finish before allocation, and the same writer fills it without growth copies.
  The returned URI owns the bytes until its caller releases them.
- **Outbound boundary copy**: `Peer.sendCopying` into `model.cloneMessage`. The
  one named copy over `send`, for drivers holding borrowed, fixed-array, or
  static input against an owning queue. Deleting it scatters the same dupes
  into every driver, one per hand-written locator and key copy.
- **Owned inbound frame**: `ownedFrameFromView` in `Peer.recvBorrowed`. The
  **only** allocation a steady-state deliver to a live export costs, and the
  irreducible wire-path floor `test/engine/alloc_budget_test.zig` asserts.
- **Recv scratch arena**: `Session.recv_scratch`. The common inbound kinds
  validate and apply straight from the borrowed `model.view.Body` with zero
  materialization. Only the two paths that _retain_ (a pipelined deliver queued
  on its answer, and the substructure-heavy `gc_*` kinds) build an owned
  `Message`, as turn scratch that dies in the `retain_with_limit` reset every
  recv entry point runs. Handoff is an argument arm on the borrowed walk, and
  `get`/`index`/`untag` stay borrowed. Apply dupes anything session-lived onto
  the gpa, so the reset never dangles a table row. Send-side folds stay on the
  gpa, because no recv turn brackets a send.
- **Introduced-import record**: `validate.IntroducedImports`. One walk serves
  validate and apply. Allocation-free for the common no-reference message, and
  depth-bounded by `SessionLimits.max_nesting_depth`, so a nested argument tree
  fails instead of overflowing the stack.
- **Introduced-import event patch**: `Event.introduced_far_imports`
  (`engine/inbound.zig`). One gpa dupe per reference-introducing deliver, because
  the event outlives the turn record. The dupe is acquired before authority
  applies; OOM refuses the transaction instead of changing the event's
  bookkeeping shape after commit.
- **Set-uniqueness scratch and compare budget**: `checkBorrowed`, `checkOwned`
  (`session/validate/set_uniqueness.zig`), `SessionLimits.max_compare_visits`.
  Borrowed sets store one 16-byte hash/checkpoint row per member. Full views
  are cached only for the largest collision run and reused between runs.
  Small rows and collision runs stay on the stack. A collided member projects
  once more, so nested Syrup scans add at most one pass over that set's region.
  Borrowed elements hash and compare as views, so no owned tree materializes,
  but two sets compare as multisets and a partner can construct an equal-hashed
  pair. Every visit charges the turn's allowance, and exhaustion refuses
  `CompareBudgetExhausted`. On Syrup this re-verifies what decode refused: one
  named redundant walk, kept so the invariant is codec-neutral.
- **Sent-resolve store**: `Session.applySentResolve`. The resolution _moves_
  into the answer row (a consume contract) and the encoder reads it back through
  `peekResolution`, which is what makes a move safe where a borrow would dangle.
  Before mutation, `ResolutionStorePlan` admits the replacement delta against
  an independent durable byte cap, which GC, promise retirement, and teardown
  release. `GlowcapSessionLimitOptions` and every binding's counterpart expose
  that cap apart from transient outbound pressure. Zero copies and no added
  Peer footprint, pinned by
  `test/engine/resolve_alloc_budget_test.zig` and
  `test/engine/node/answer_settlement_test.zig`.
- **Listener fire carriers**: `engine.Outbound.listener_fire`,
  `Session.store_stamp_counter`. POD carriers over the stored resolution or a
  live export's near fulfill. Zero payload copies. Queue-time retains pin the
  payload's `near` exports across the queue-to-encode window against a legal
  partner `op:gc-exports`, which is why fire accounting cannot move to encode
  time. Row identity stamps make a released-and-reused position leave the fire
  moot instead of shipping another row's payload. Pinned by
  `test/engine/listener_fire_budget_test.zig`.
- **Outbound byte accounting**: `Peer.queuedOutboundBytes`. One machine word
  per peer, updated where the outbound queue takes or transfers frame ownership,
  so a byte-fed host's backpressure check is O(1) and re-walks no queued
  frame. At 500,000 sessions the fixed
  charge is about 4 MiB. The peer struct and warmed-state checks hold it.
- **Relayed resolution**: `Peer.applyRelayedResolution`,
  `Session.recordRelayedResolution`. Lower in place (this path bypasses `send`'s
  chokepoint), move into the store, fire from the store. Written exactly once, so
  a second relay is refused. A terminal Node relay that cannot prepare listener
  carriers commits the store and increments one `u32` retry count on the Peer.
  Only while nonzero does `step` scan imported-promise rows for stored values
  with listeners. No clone anywhere on the single-store path. Held by behavior
  tests, not a budget test.
- **Proxy fan-out**: `proxy_admission.foreignPromiseFulfill`,
  `passable_batches.stage`. One home `op:listen` is shared across recipients,
  never N listens. The Host lifts the fire once. Each recipient owns one bounded
  materialization because its references, gives, and promise positions differ.
  Admission owns one fixed terminal-break buffer and action seat per recipient,
  so projection, signing, entropy, or teardown failure cannot strand it.
  Object occurrences mint one recipient-addressed give each. Promise
  occurrences share the existing home-listener machinery. Bounded by
  `Node.max_proxy_recipients` and the recipient queue cap. The recipients'
  staging shares one arena per fire, reset between recipients under
  `steady_proxy_recipient_arena_bytes`, so a full fan-out pays one backing
  allocation, not one per recipient.
- **Inline Passable projection staging**: `Node.stageOutbound`,
  `Peer.reserveInlinePassableStaging`. One owned message waits for gift ids,
  shared promise listeners and recipient escrows. No partial rewrite, deposit,
  proxy listener or recipient import is visible. Staged bytes and occurrences
  stay under the recipient's outbound waterline and queue cap. Deposits for one
  exporter are admitted together. Commit moves the message without another clone.
  `Peer.publishAnswerRelease` owns a bounded POD carrier, including before staging
  completes. A release flag fits the staged row's 32-byte budget. Success transfers
  it to Session, and failure drops it. Public release copies no position array.
- **Projection anchors**: `Peer.respondToProjection`. One dupe of the field name
  or tag, because the projection outlives the view that carried it. `op:index`
  dupes nothing. Bounded per answer by `max_listeners_per_target` (ADR-0050).
- **Local-delivery frame synthesis**: `Peer.deliverDrainedCallLocally`. One
  synthesized frame, which the frame-based event model requires: a borrowed frame
  cannot carry a message that never arrived on the wire. Bounded by
  `max_local_deliveries`. Named, not measured.
- **Partner location and key arena**: the `start_session` arm of
  `session/apply.zig`, into `Session.key_arena`. Session tables are authoritative
  and outlive any frame, so the partner's session key and location bytes are
  duped in. When decode supplies verbatim location bytes, **that one buffer is
  the sole owner and the designator is a relocated subslice of it**, not a second
  dupe. Owned-apply has no raw bytes and keeps a designator-only dupe. Every
  byte-keyed table is O(1), not a `std.mem.eql` scan. **A bump arena is
  the right owner only because those tables never remove a row**, which is why
  the FIFO-evicting `sturdyref_cache` and the individually-removed
  `pending_enlivens` keep their bytes on the gpa instead.
- **Sturdyref FIFO topology**: `sturdyref_cache.Entry` retains two inline row
  indexes per admitted cache row. No additional allocation or idle Session
  footprint. Dense removal repairs only relocated rows, bounded by the cache cap.
- **Resolver-export link**: `Session.outbound_resolver_link`. One POD row per
  live listen (ADR-0095), no owned bytes.
- **Shortening GC closure**: `expandGcExportReleases`. Rare outbound-GC
  scratch plus replacement position/delta slices keep edge-owned import retains
  in the same wire operation as the caller's release, recorded as the two
  releases they are: the caller's prefix through `recordSend`, the session's
  trailing closure through `recordSessionImportRelease`. Ordinary sends
  allocate nothing here.
- **Session-held import retains**: `ImportRow.session_held`. One word per
  import row. It names which of a row's retains
  the session releases itself (a linked V1.0 resolver's, a pending listener's,
  a stable shortening edge's), so a caller's release is bounded by
  `ImportTable.releasable` and the fire that later addresses the row finds it.
- **Sturdyref enliven dedup**: `Session.notePendingEnliven` (ADR-0012). One
  swissnum dupe per in-flight row, moved into the resolved cache on fulfillment.
  A full resolved cache evicts before insertion. An in-flight row reserves both
  cache structures before committing the fetch, so allocation failure refuses
  the enliven transaction instead of silently disabling dedup.
- **Owned Host enlivenment**: `Host.enlivenCapability` allocates one fixed-size
  operation from the caller's allocator, with an inline bounded failure message.
  `enliven/group.zig` reserves one group, member, vow and answer-release carrier
  before admission. Followers keep their member and vow and retire the unused
  group reservation. One Host-wide pending index adds 24 inline bytes and no
  session storage. The group owns the sole wire listener and GC carrier through
  the last observer or public pipeline handle. Each result owns its own retain.
  A temporary capability retain protects shared projection through the callback
  turn. `HostRuntime.enliven` consumes the owned result directly, removing its
  cache-completion parking state. A parked row carries one recipient union.
  Its locator bytes retain their existing Host owner. Cancellation releases
  observation storage without copying a result or allocating a GC carrier.
- **Freed export ranges**: `engine.Node.freed_export_bases`. Export ranges are a
  fixed budget, so a released session's range comes back and is re-handed
  oldest-first. Registration reserves the exact future return slot before the
  range becomes session authority, making release infallible under allocator
  pressure. No layer above keeps a session's base.
- **Canonical set and struct ordering**: `writeCanonicalSet`,
  `writeCanonicalStruct`, `writeHintDict`, `encodeArgumentSetList`,
  `Builder.finishCopying`. Encode each element once and sort the encodings, turn
  scratch freed before encode returns. **Sorting on model values instead lets two
  encoders disagree. The bytes are the only order both sides reproduce.** A Cap'n
  Proto set element snapshots its framed bytes because its builder stays live for
  the graft that follows. An ordinary Cap'n Proto message copies none of its
  encoded bytes: the builder reserves the segment-table word ahead of the
  segment and `Builder.initial_words` ahead of the growth cliff, so `finishOwned`
  hands its one allocation to the frame. The trim `finishOwned` ends on is
  in-place on the allocators glowcap ships against. One that cannot shrink there
  falls back to `std`'s copy.
- **Boxed handoff argument**: the handoff arm of `view.zig`'s
  `Argument.toOwned`. Boxed so the largest arm does not set the size of _every_
  `Argument`. `src/ocapn/model/mod.zig` asserts 40 bytes for `Argument` and 48
  for `Resolution` at comptime, so un-boxing fails the build.
- **Crypto fixed-width materialization**: `crypto.PeerKey.fromSlice`,
  `crypto.Signature.fromParts`. `std.crypto` takes fixed arrays and offers no
  allocator pattern. The wire has slices.
- **Give-location dialable form**: `handoff_gifter.exporterLocationForRecipient`.
  One decode-and-re-encode per give whose *onion* exporter hello carried
  `glowcap/*` profile hints and whose recipient is not known to be glowcap
  (ADR-0118). Every other give — every non-onion transport, every Goblins
  exporter — takes the null path allocation-free and embeds the verbatim
  hello bytes its receiver's withdrawal keying matches. The derivation lives
  at the declaration.
- **Handoff canonicalization**: one owned signing-domain buffer per certificate.
  An immediate withdrawal never owns the inbound tree. A Syrup-forwarded give
  carries its exact signed envelope, so receive bypasses typed hints; Cap'n
  Proto's lazy hints project into bounded scratch freed before return.
- **Gift registry**: `engine.bootstrap.gifts.GiftRegistry`. A lazy per-`Peer`
  owner keeps rows on the gpa with precise frees, **never a bump arena**, which
  cannot reclaim an overwritten row and would leak every re-deposit. Whole-row
  requested bytes — map key/slice, payload tag, opaque id, provenance, and
  variable owned reference data — are admitted before allocation or authority
  adoption, then charged exactly through replacement, withdrawal, and teardown.
  The outbound message is built and queued before an infallible commit removes
  the gift, so queue OOM leaves it retryable. **Because a consumed row is gone,
  the row count _is_ the live-gift count**, so `max_deposited_gifts` needs no
  parallel counter. `max_deposited_gift_bytes` owns cumulative retained size.
- **Swissnum miss diagnostic**: `resolveForSwissnum` (`engine/bootstrap.zig`).
  One string dupe on the unknown-name break path, because the diagnostic must
  outlive the resolving frame and `send` frees the resolution it rides in. The
  fulfill arm is POD and allocates nothing.
- **Parked withdraw**: `Peer.pending_withdraws` (ADR-0100). One compact verified
  claim per early `withdraw-gift`, retaining neither signature, exporter locator,
  receiving names, nor signed envelope. Bounded by `max_pending_withdraws` and
  the session's `max_frame_bytes`. Refusing the early withdraw instead would
  break the deposit-may-arrive-second contract the upstream suite pins.
- **Handoff coordination**: `Node.handoff_waiters`. Scheduler state, never
  authority. **The fixed-size 128-bit BLAKE3 gift tag is what keeps a
  partner-chosen gift-id length out of coordination state**. Signed bytes stay
  the authority, so a collision costs one bounded retry. Deposit and close
  notification allocate nothing after the first group.
- **Redeem dial parts**: `Node.stageDial`. Parse the exporter URI once
  into identity and dial parts, keep no verbatim URI, and carry only the ticket
  in `Node.Action.dial` / `HostAction.dial`. An unparseable locator fails closed
  with no staged heap. **No re-parse anywhere on the redeem dial path.**

### Actor layer

- **Opaque ingress custody**: `OpaqueMessage` charges its requested bytes before
  guarded copy admission. `local_delivery.Input.copy` materializes verb, Value
  spines/leaves and keeper retains in the existing queue arena. The queued target
  and every capability occurrence outlive observer cancellation. Callback
  observations acquire independent retains. Projection refusal releases them
  before callback entry. Consuming retirement prevents repeated cleanup across
  dispatch, rollback, ingress cancellation and teardown. The ordinary queue row
  is 72 bytes on 64-bit, with 56 turns per chunk. Footprint tests pin both.
- **Archive-neutral actor callbacks**: `HandlerFailure` carries immutable
  archive-owned text and scalar error-domain metadata on the call stack.
  The producing archive catches the error. Receivers recover a typed ordinal
  only in that compilation. No allocation, payload copy or traversal is added.
  `OpaqueMessage.VTable` adds one constant 16-byte protocol identity, independent
  of its address. `Vat.turn_failure` retains an optional text slice for rollback,
  adding 16 inline bytes on 64-bit. Sessions and queue rows gain none.
- **Owning local completion**: `local_delivery.Producer` and `VowRow` cost
  312 and 152 bytes on 64-bit. The reply destination tag adds one inline word.
  Warm admission allocates those two owners;
  `Host.Call` separately allocates its 328-byte operation and exactly the
  configured reply backing. Reply preparation copies Value spines/leaves and
  acquires occurrence retains before state replacement or resolver consumption.
  `completion.retainValue` uses the stable Value as its rollback receipt,
  without another inventory allocation or capability-count walk.
  `ReplyAllocator` is a synchronous stack proxy over the fixed backing. Its
  refusal latch distinguishes reply capacity from Host heap pressure without
  another allocation, copy, walk or persistent field.
  Local forwarding reuses that Producer, row and reply backing. Each hop owns a copied
  input and the existing forwarding context. Measurements cover caller demand,
  warm admission, terminal live bytes and heterogeneous logical copy demand.
- **Public local reply**: `local_completion.Reply` embeds the Producer in one
  384-byte allocation on 64-bit, plus the existing 152-byte public vow row.
  One arena materializes trusted output and moves into the reserved Host action.
  Preparation/publication and queue adoption preserve the same pointers.
  A child queued inside a running parent also needs the existing overlapping
  queue chunk and its backing: measured warm send/tell admission costs four/three
  allocations. Tell uses only its 312-byte discard Producer and queued input,
  with no Call, Host vow row or reply allocation. Constructor refusal, deferred
  preparation retry and aggregate retirement pin custody.
- **Foreign owning answer transfer**: `foreign_forward.ForeignForward` embeds
  the existing `ForwardContext`, actual peer and original Producer custody in one
  64-byte box on 64-bit. The observed wire vow owns that box and answer-release
  reservation. `prepareWire` projects once into the original fixed reply buffer.
  Canceled observers discard wire occurrences. No child Call or resolver pair
  is created. Tests pin caller allocation count and terminal custody.
- **Ingress clone**: `Vat.send` / `Vat.tell`'s local arm, over
  `model.cloneArgumentSlice`. `sendCopying`'s contract inside one vat: a queued
  turn runs at a later `drive` whose first outermost turn resets the very arena
  the handler built its args in. `model.measureArgumentSliceOwnedBytes` walks the
  same shape first, so admission refuses a limit **before any queue mutation**.
- **Far notifications**: `AnswerCell.application_notification_consumed` guards
  one-shot observation within its 48-byte row. `Port.far_listeners` uses dense
  indexed storage: a 16-byte larger header supports O(1) bulk removal while other
  listeners remain cancellable. Bulk failure frees the store without allocating.
  A Port cutoff refuses old vows, with no completed-answer map.
- **Settle clones**: `Vat.settle_arena`. Each defends two hazards, which is why
  it can be re-homed but never deleted: a listener may open a top-level turn
  whose depth-0 reset frees a turn-arena value mid-call, and the value may borrow
  the settling actor's own state, which a listener-run turn can mutate or
  `become`-free. Depth-guarded, so it covers a nested drive and a far listener
  re-entering `serve` through a driver pump.
- **Far send verb splice**: `farDeliverTo`. Stack buffer to seven args, then one
  immediately-freed gpa spine — **never the turn arena, because the path is
  callable at depth 0**, where a bump pins until the next outermost turn.
- **Turn failure callbacks**: `reserveBreak` in `actors/vat/turn_commit.zig`.
  Answered far sends reserve shared Vat storage before publication so rollback
  can defer listeners until all participants have undone their effects.
- **Reply sever on install**: `callWithOrigin`. Clones the reply onto the turn arena
  when a `become` will install at this frame's unwind, because the install frees
  the box the reply may borrow. **The gate is the install, not this frame's own
  staging.** An ordinary near-call still returns its reply borrowed, and `serve`
  needs no clone at all, because it copies onto the wire inside the turn window.
- **Moved replies**: `Turn.moveOut` / `moveOutString`, `Vat.moved_replies`. A
  handler that owns its reply's bytes _transfers_ them instead of paying the
  sever, and `callWithOrigin` skips the sever only on pointer identity with that
  turn's own moves, so a reply borrowing any other state is still severed.
- **State boxes**: `StateBox`, `releaseBox`, `ensureUnshared` (ADR-0060). One
  refcounted heap block per actor, so `Vat.snapshot` shares boxes at zero bytes
  copied and a non-snapshotting actor pays one pointer indirection. Deleting the
  layer forces an eager O(total-mutable-bytes) snapshot copy.
- **Retired boxes**: `Vat.retired_boxes`. A `become` install swaps the cell's
  box but its reference falls at the next outermost turn, because an _earlier_
  frame of the same actor may already have returned a reply borrowing it, leaving
  no live frame to copy it. Registration escrows one pointer slot per live actor
  so last-root release and teardown never allocate. `stageBecome` additionally
  reserves one slot per open frame, not per stage. Burst backing is replaced
  transactionally at the next outer-turn boundary, while the live-actor escrow
  remains.
- **Forwarding callback identity**: `Vat.forward_listener` retains one function
  pointer per Vat, shared by every owned forwarding context. Native archives
  publish and classify through that exact identity, so teardown and iterative
  settlement do not depend on process-wide identity of compiled private functions.
  The Host footprint check pins the eight-byte native charge. Listeners and
  sessions gain no fields or allocations.
- **Turn-forward context**: `reserveForward` owns one `ForwardContext` per
  answered eventual forward. Tells allocate none. Local chains settle iteratively.
  Settlement or `freeOwnedForwardContexts` frees it. `forwardTurnVow` also owns a
  32-byte `ForwardRegistration` until commit or abort, so an existing vow loses
  only the failed turn's listener. Other forwarding contexts gain no fields.
- **Dynamic turn break**: `Turn.breakWith` copies a queued call's diagnostic
  into the turn arena before foreign callback storage expires. `settleLocal`
  copies it into its depth-guarded settle arena before listener reentry.
- **Actor roots**: one `u32` per row (ADR-0101). Each relationship holds one
  root, transferred at the seam that owns it. Root zero retires the row past any
  running frame and parks the box on the retirement capacity registration
  escrowed before the actor became visible.
- **Persistent map nodes**: `collections.PersistentMap` (ADR-0061). O(log n)
  fresh nodes per write with refcounted structural sharing. An immutable trie is
  acyclic, so the count frees with no collector, and retains happen only after
  every allocation in a rebuild succeeds. Rebuilding whole makes `become`
  O(size).

### Transports, loops, and streams

- **Inbound spill**: `foundation.Spill` (ADR-0041). Where stream bytes wait
  before they make a whole frame. **It is bytes and nothing else, which is what
  lets `net` and `driver_core` share it** when neither can import the other, and
  each tier names only what a drained spill keeps. Deleting it relocates the cost
  into `max_frame_bytes`-sized per-connection read buffers.
- **Byte-fed stream tail**: `HostSession.feed_tail` via `Host.feedBytes`. The
  one owner of the tail four binding pumps each kept by hand. Zero copies with no
  pending tail, and one bounded coalesce per chunk while one is pending. A
  straddled chunk is ordinary here, so this tier retains
  `steady_feed_tail_bytes` instead of freeing outright.
- **Sealed byte channel**: `foundation.sealed.SealedChannel` (ADR-0107), one
  channel type with one owner: the byte-fed `HostSession` boxes one per sealed
  session (the unsealed shell pays one null pointer), so every transport
  resident carries sealed bytes unchanged. The channel stages inbound wire in its own
  spill, bounded by one record plus a chunk tail, and opens each record into a
  plaintext scratch shrunk back to steady size by the next small record.
  Sealing and opening pay the one AEAD pass per record ADR-0107 names;
  `sealFrame` allocates one owned wire frame per outbound frame, `sealBytes`
  seals a stream chunk into a caller-owned queue, and `takeWire` dupes the
  fixed-size pending handshake message. Deleting the box moves key material
  onto every shell in the 500k budget. Deleting the record copy means
  encrypting over borrowed frame bytes the engine still owns.
- **Shared read-buffer pool**: `completion.BackendOptions.read_buffers` ×
  `completion.BackendOptions.read_buffer_bytes` (ADR-0054). An idle
  connection holds zero read-buffer bytes. Whole frames apply zero-copy from the
  pool view and a partial tail pays one bounded copy into the spill. **The
  zero-copy claim is scoped to spill-inactive.** Deleting the pool reopens the
  per-connection buffer floor, about 7.6 GiB at 500k, and deleting the tail copy
  means parsing across recycled storage.
- **Readiness pending-operation rows:** `epoll.Backend.pending` and
  `kqueue.Backend.pending`. One compact row joins each descriptor with its
  armed read and write completion identities. The map grows when concurrent
  armed descriptors reach a new peak, then retains that capacity so steady
  re-arm is allocation-free.
- **Outbound queue front and back**: `completion.Loop` (ADR-0042). One copy in,
  because the loop cannot block on a send. **Two buffers because a submitted
  write borrows `front` while the loop keeps running**, and appending could
  realloc that storage out from under the kernel. Steady retention is
  per-buffer, so the ceiling is 32 KiB per connection, not 16. Bounded by read
  backpressure at `completion.Options.outbound_high_water_bytes`, whose
  independent 64 KiB default is replaceable without changing admission or pool
  sizing.
- **Completion-adapter transport staging**: iroh `enqueue_outbound` and
  keyed-relay `queueFrame` (ADRs 0057 and 0088). The Loop's submitted send is
  a borrow, while both foreign async engines must own bytes past the call: iroh
  copies the admitted prefix into one queue whose queued plus in-flight bytes
  share `NB_BUFFER_BOUND`. Keyed-relay keeps the external write borrowed through
  its one completion and copies and masks one bounded WebSocket chunk at a time
  into `RelayConn.ws_out`, as RFC 6455 requires. The unsent tail is a subslice of
  the Loop-owned borrow, including while a Pong owns the wrapped send seat: a
  second whole-write copy is forbidden.
  Iroh's inbound twin, `nb_reader`, appends each QUIC chunk once into the
  connection's bounded inbound buffer, and `conn_try_read` drains it by
  advancing an offset, compacting only when the consumed prefix reaches the
  pending bytes. The buffer tracks the bounded pending count, not the bytes ever
  received, and shrinks back to `NB_STEADY_BYTES` once drained. Iroh retains at
  most one `NB_STEADY_BYTES` spare after a drained burst. Relay send staging
  retains at most `RelayOptions.send_staging_bytes`, 4 KiB by default including
  the frame header. A larger override is a per-connection memory commitment,
  not a frame-admission limit. WSS copies ciphertext once into its fixed TLS
  record window and writes decrypted bytes directly into that WebSocket staging
  path. Refused TLS sends retry from allocation-free intrusive links in bounded
  turns, without cloning the application payload or adding a per-connection
  thread.
- **In-process link rings**: `Link.create` sized by `Exchange.ring_bytes`
  (ADR-0193). One allocation per `inproc` link holds a bounded ring per
  direction, the in-process counterpart of a socket's kernel buffers: a write
  copies into the ring and a read copies out into the reader's pool buffer.
  Peers on two loops cannot borrow each other's send buffers past the call, so
  the ring is the one owner between them, and its bound turns a fast writer
  into would-block.
- **Foreign-provider receive copy**: `external_completion.CompletionBackend`
  (ADR-0193). A provider owns its connection's bytes, so each `try_read` copies
  into one buffer from the backend's shared pool, the same shape as iroh's
  `conn_try_read`. Writes stay borrowed through the provider's `try_write`,
  which copies only what it accepts. Rows hold handles and readiness
  descriptors, no bytes.
- **Completion-resident send staging**: `completion_resident.Resident`
  (ADR-0202). `try_write` hands bytes over on return while the backend borrows
  a send until it completes, so each connection copies into staging bounded by
  `send_window_bytes`. Drained buffers return to one resident-wide spare list
  bounded by `spare_send_buffers` and `spare_send_bytes`, so an idle
  connection holds none. Reads cost no copy here: the resident lends its held
  pool receive through the borrowed-read group.
- **Wrapped-backend ready-queue reservation**: the onion, noise, and
  keyed-relay completion adapters (`ReadyQueue.ensureUnusedCapacity` before
  each poll turn). Consuming one inner completion may terminate a connection
  whose external connect, recv, and send seats each owe a record, and onion's
  close handshake owes one more, so each adapter reserves that whole fan-out
  (three or four records per inner completion, times the 256-record turn)
  before it takes any inner completion from the backend it wraps. An
  already-earned record is never lost to a refused reservation. The queue keeps
  that peak, about 36 KiB (48 KiB for onion) per adapter, for the backend's
  life: `appendAssumeCapacity` is what makes fan-out infallible mid-turn, and a
  shrinking queue would give that back. Stacked adapters each hold their own.
- **Onion listener publish setup**: `onion/completion/listener.zig`. While
  the publish conversation runs, the one listener row holds about 2 KiB of
  setup state (the outbound control line, the reply-line assembly buffer, and
  the reply harvest), transient for the setup's bounded life and freed when
  the service publishes or the setup fails. The steady-state listener row
  holds only the descriptor and the published service. The setup state is per
  backend (one backend publishes one service), so no per-connection cost
  exists.
- **iroh provider connection-id table**: `MultiplexedAdapter`
  (`src/net/transport/iroh/multiplexed.zig`, ADR-0184). One POD row per live
  loop connection, mapping the sidecar's stable id to its handle, because
  drained records carry ids while the sidecar verbs take handles. Rows enter
  at `finishConnect` or `finishAccept`, free at `closeConnection`, and adapter
  teardown sweeps stragglers. No byte payload crosses the table.
- **Keyed-relay configuration and carrier lease**: `keyed_relay.Resident`
  copies its relay, registration and optional dial alias URLs into one block
  because parsed `RelayUrl` fields are retained views. The completion backend's
  registration (`registration.State`) copies its URL the same way and keeps a
  fixed ring of promoted, unaccepted legs per backend, so a full backlog pauses
  registration instead of growing. One heap `carrier_runtime.Lease` state owns
  I/O per resident. Each listener and admitted channel retains one
  pointer-sized lease, so the last release follows their close barriers. There
  is no per-dial config copy.
- **Keyed-relay receive projection**: the completion adapter lends ordinary
  WebSocket payload directly from the wrapped backend's shared recv buffer,
  preserving its token so recycle returns to the actual owner. Only a split
  header or control frame, upgrade residue, or the next-frame tail coalesced
  behind a payload crosses into `RelayConn.raw_in`. A platform receive that
  completes after its caller seat was canceled also copies there so stream
  bytes survive recycling the shared buffer. A replacement seat installed
  before completion still takes the ordinary zero-copy path. The spill is
  hard-bounded to one platform buffer plus the parser prefix, and capacity
  above `steady_raw_in_bytes` is released when drained. The blocking resident
  still copies from its socket reader into the caller's CapTP reader.
- **WebRTC C-facing staging**: one bounded inbound deque and one bounded
  outbound staging buffer per peer (ADR-0089), because the C ABI exposes
  synchronous reads and nonblocking try-writes while the `webrtc` 0.20 data
  channel is async. The inbound poller admits a message only when the whole
  message fits under `INBOUND_BUFFER_BOUND`, and it refuses a single message
  larger than that budget. Try-writes copy into the outbound staging buffer and
  return without entering the runtime. An async drain task sends bounded chunks
  through `DataChannel::send`. The crate's SCTP receive window and send buffer
  are separately bounded at the same layer. Readiness is endpoint-owned, and its
  self-pipe writes distinguish sent, safely coalesced, and failed outcomes.
  `WouldBlock` alone is coalesced success because unread bytes already make the
  fd readable. Every other write or drain fault is latched by the owning
  runtime and settles or terminalizes its admitted work. Locally gathered ICE
  candidates are retained only in that peer's signaling queue, capped at 256
  records and 64 KiB total text. Overflow terminalizes the peer as a transport
  failure.
- **WebRTC signaling transfer**: `SignalPayloadPool` in the native completion
  backend. `provideAnswer` and `provideRemoteCandidate` are callable from
  foreign threads, while a caller-supplied Zig allocator may be single-threaded.
  The backend therefore allocates one fixed 4 MiB endpoint-level pool on its
  owner thread and copies each bounded signaling payload into an exclusive slot
  before publishing the queue row. The loop returns the slot after applying the
  row. No foreign thread enters the allocator, no payload allocation reaches the
  session byte path, and overload is `WouldBlock`, not heap growth.
- **Browser WebRTC candidate staging**: `RtcPeer` snapshots the standard ICE
  fields before retaining a remote candidate, caps one candidate at 4 Ki text
  units, and caps each pre-SDP or apply queue at 256 candidates / 64 Ki text
  units. Local candidates waiting for a signaling sink carry the same bounds.
  Once a sink is installed, `SignalingSendOwner` admits at most 256 unresolved
  signaling sends and aborts bring-up on overflow. The rooms carrier creates
  one row per active dial before gathering starts, holds early local candidates
  behind the directory's admitted exchange id, expires routing rows after 30
  seconds, and retires that exact id when bring-up ends. These queues are
  signaling control state, not session bytes, but remain peer-influenced
  when the signaling capability crosses a network.
- **Pinned stream wrapper**: `netlayer_support.PinnedRawStream` for a raw
  socket connection (`tcp`, `onion`) and `netlayer_support.PinnedStream` for a
  shim-sourced one (`inproc`, `IrohStream`) (ADR-0043, ADR-0055).
  `std.Io.Reader`'s vtable recovers its concrete reader from `&interface` by
  field offset, so the reader and writer need a stable address outside the
  by-value `Connection`. Storing them inline dangles the moment the connection
  moves. Two shells because the sources differ in kind: a raw socket already
  owns std's reader and writer, and shimming it would add a second buffer and
  a copy. Blocking path only. The loop builds no `Connection`.

### Host tier

The [Host inventory](references/host.md) owns runtime handles, value projection,
session routing, and capability custody costs.

### Named deferred costs

These costs are named where they are, not forbidden. Relocating one does not
delete it, so the name stays here.

- **Binding dial OS-connect string**: each binding decodes `host` and
  `addresses` once after `glowcap_host_plan_dial`, because the OS connect API
  needs a language string. A second rematerialize of the same view through
  `readMemory` / `string_at` / `bytes<-c` is forbidden.
- **Rust received capability custody**: `gc::owned_guard` allocates one shared
  guard for each owned C occurrence, including local callback observations.
  Clones share that guard. Independently received equal ids keep distinct
  native retains. Its declaration owns the lifetime and cycle derivation.
- **Binding outbound flush copy**: TypeScript, Python, and Racket copy
  managed-frame bytes and release before the async write; Rust holds the frame
  across it. Language and lifetime forced: no change without a hold-across-await
  proof. The C descriptor keeps its native `Frame` owner inline and allocates
  nothing. Each copying binding reuses one descriptor/prefix scratch set per
  serialized Session drain, so only the named payload copy remains per frame.
- **TypeScript native-connection write copy**: `AsyncFfiWriteQueue` snapshots a
  caller-owned frame before off-thread TCP, inproc, or onion FFI can borrow it.
  No single frame or admitted set may cross the connection's frame-scale byte
  waterline. Later writes are refused until ownership retires, and a separate
  16-write cap keeps zero-length calls from retaining an unbounded promise
  chain.
- **Racket inbound `pin-immobile`**: every `feed_bytes` path pins the buffer
  into collector-immobile memory first. The tail lives in the core session, so no
  binding-side coalesce rides on top.
- **Wasm linear-memory boundary**: `bindings/ts/web/adapter.ts` (ADR-0070).
  JavaScript cannot lend wasm a view, so every buffer argument pays one copy in
  and each `outBuffers`-marked out-parameter one copy back. **Do not delete the
  memoized re-stage's resync as an optimization**. Staged copies retire two
  outermost-call windows later, because a call's returned views alias its staged
  inputs.

The [Loam inventory](references/loam.md) owns durable storage, hosted calls and
C/Rust projection costs. The [Rooms inventory](references/rooms.md) owns
managed session execution and archive retention costs.
