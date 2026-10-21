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
- **Outbound boundary copy**: `Peer.sendBorrowed` into `model.cloneMessage`
  and `cloneResolution`, for the kinds the queue keeps past admission when a
  driver lends borrowed, fixed-array, or static input: a hello, a release, a
  listen, a resolution, and a deliver whose tree lists a reference, handoff,
  or set, because the session rewrites those slots in place and the Node may
  hold the tree while it stages a handoff. A deliver that lists nothing is
  encoded before the call returns and copies nothing (ADR-0064), and one
  whose values are lent as views leaves the same way through
  `Peer.sendFreight` (ADR-0064). Deleting the clone scatters the same dupes
  into every driver, one per hand-written locator and key copy.
- **Borrowed reply retention**: `outbound.copying.answerTargetView`
  (ADR-0063). A served Host reply with no capability stays a view through
  interception, then copies directly into the answer store. The store serves
  later listeners and pipelined operations after the turn and frame retire.
  The Host builds no temporary model containers for this reply. A near
  caller receiving explicit views materializes them in `callWithOrigin`
  before actor replacement, which also removes the need for a sever copy.
- **Outbound tree inventory**: `session.inventory.ofMessage` and
  `ofResolution` (ADR-0064). One walk at admission certifies a sent tree's
  depth, struct keys, and retained bytes, and lists the slots that hold a
  reference, handoff, or set, so lowering, shortening, the Node's projection
  passes, reference certification, and export recording loop over the list
  instead of walking the tree again. The list is one allocation per
  inventoried tree that has such a slot, freed when admission ends, and a
  tree with none allocates nothing (`test/session/inventory_test.zig`).
  `PreparedDepositGift` retains that same inventory through commit or
  abandonment, so the infallible commit never allocates a replacement walk.
  Freight, a tree lent as views, takes `Session.certifyFreight` instead
  (ADR-0064): the same rules in one walk that lists nothing, because a
  reference in it is refused, and whose set fold borrows its elements.
- **Owned inbound frame**: `ownedFrameFromView` in `Peer.recvBorrowed`. The
  **only** allocation a steady-state deliver to a live export costs, and the
  irreducible wire-path floor `test/engine/alloc_budget_test.zig` asserts.
  The block carries the message's parse in its head (`Frame.initHeaded`), so
  a message is parsed once at admission and the queued row stays narrow.
  Carrying the parse in the row instead parked it on every warmed session,
  and freeing the row's queue at each drain cost a second allocation per
  turn (`test/engine/footprint_budget_test.zig` and the allocation budget
  hold both ends).
  - The head also lends argument views behind the parse (ADR-0063):
    `head_argument_views` for a frame up to `small_frame_bytes`, then one per `head_view_bytes` of wire up to `head_views_cap`, so a
    deliver's argument tree is parsed once and validation, the Vat, and the
    Host's lift walk views: a handler's `actors.Delivery` reads the frame's
    bytes where they lie (ADR-0063), and a Host handler's `driver.Args` does
    too when validation counted no reference or handoff slot in the deliver,
    so the lift runs only for a deliver that carries a capability
    (ADR-0063). `inbound_head_budget_bytes` pins the
    fixed head, the cap pins the views, and the cost is transient, freed
    with the frame. A Syrup list of integers is parsed into words in the
    head's unused room instead (`ValueSlab.beginIntegers`, ADR-0063),
    committed only when every element fits `i64`, so it costs no view
    per element, no turn copy, and no allocation of its own. The same bytes
    hold struct entries (ADR-0063). Typed claims spend their actual byte size,
    and an overflowing Syrup collection releases its cached children before
    falling back to the wire. The head budget and allocation count stay fixed.
  - The block comes from the peer's allocator on every frame: keeping one
    per peer measured no gain (ADR-0063).
- **Boxed parse**: the boxed arm of `events.Parse.decode`. A frame that reaches admission
  without the engine's head (`Peer.feedOwned` from a caller's own storage,
  an external frame, a pipelined rewrite the codec encoded) gets its parse
  boxed once, so the row and the drain stay one shape. The engine's own
  inbound materialization never pays it. A V1.0 resolver callback is the
  one other boxed case (`events.Parse.storeTranslated`): admission keeps the
  deliver as it arrived beside the resolve it means, so `Event.view` hands
  out a borrowed pointer on every path and nothing is translated twice.
- **Recv scratch arena**: `Session.recv_scratch`.
  - The common inbound kinds validate and apply straight from the borrowed
    `model.view.Body` with zero materialization. Handoff is an argument arm on
    the borrowed walk, and `get`/`index`/`untag` stay borrowed.
  - A pipelined deliver queued on its answer builds an owned `Message` on the
    peer's allocator, because the queued call outlives the turn: it is freed
    when it drains or its answer retires, and the pipelined queue cap bounds
    it. The substructure-heavy `gc_*` kinds build theirs as turn scratch that
    dies in the `retain_with_limit` reset every recv entry point runs.
  - Apply dupes anything session-lived onto the gpa, so the reset never
    dangles a table row. Send-side folds stay on the gpa, because no recv turn
    brackets a send.
- **Introduced-import record**: `validate.IntroducedImports`. One walk serves
  validate and apply. Its mention lists and its distinct-fresh table hold
  their first rows in place (`foundation.inline_rows`), so a message with a
  few references allocates nothing, and a longer one spills to the record's
  allocator once. Depth-bounded by `SessionLimits.max_nesting_depth`, so a
  nested argument tree fails instead of overflowing the stack.
- **GC fold scratch**: `session/gc.zig` and `answers.prepareGc`. Each
  `op:gc-*` folds its repeated positions in a record that holds eight rows in
  place and spills to the recv arena past that, so an ordinary release
  allocates nothing and an adversarial vector of many distinct ids still
  validates in one pass.
- **Introduced-import event patch**: `Event.introduced_far_imports`
  (`engine/inbound/deliver.zig`). One gpa dupe per reference-introducing deliver, because
  the event outlives the turn record. The dupe is acquired before authority
  applies, so OOM refuses the transaction instead of changing the event's
  bookkeeping shape after commit.
- **Set-uniqueness scratch and compare budget**: `checkBorrowed`, `checkOwned`
  (`session/validate/set_uniqueness.zig`), `SessionLimits.max_compare_visits`.
  - Borrowed sets store one hash/checkpoint row (a `u64` each) per member. Full
    views are cached only for the largest collision run and reused between
    runs. Small rows and collision runs stay on the stack. Spills are freed
    before return, including refusal, so outbound folds need no recv arena.
  - A collided member projects once more, so nested Syrup scans add at most one
    pass over that set's region. Borrowed elements hash and compare as views,
    so no owned tree materializes.
  - Two sets compare as multisets, so a partner can construct an equal-hashed
    pair. Every visit charges the turn's allowance, and exhaustion refuses
    `CompareBudgetExhausted`.
  - On Syrup this re-verifies what decode refused: one named redundant walk,
    kept so the invariant is codec-neutral.
- **Sent-resolve store**: `Session.applySentResolve`. The resolution _moves_
  into the answer row (a consume contract), and the encoder reads it back through
  `peekResolution`, which is what makes a move safe where a borrow would dangle.
  - Before mutation, `ResolutionStorePlan` admits the replacement delta against
    an independent durable byte cap, which GC, promise retirement, and teardown
    release.
  - `GlowcapSessionLimitOptions` and every binding's counterpart expose that cap
    apart from transient outbound pressure.
  - Zero copies and no added Peer footprint, pinned by
    `test/engine/resolve_alloc_budget_test.zig` and
    `test/engine/node/answer_settlement_test.zig`.
- **Inline next subscription**: `deliver_resolver.prepare`. Prepares the
  answer payload and ordinary listener backing before publishing an inbound
  result-producing call. Refusal frees both; commit transfers them to the
  answer store. Deliver-only has neither cost.

  `answers.QueuedCall` retains
  the exact reply name and row stamp in the existing bounded pipeline queue,
  so calls sharing a resolver capability or reusing a released answer position
  cannot alias reply ownership. Its argument-import slice preserves the original
  wire mentions across shortening. It transfers to a local event or forwarding
  GC and frees on refusal. Rewalking rewritten arguments cannot recover that
  ownership. Local replay reverses descriptor perspective in its owned tree
  before encoding the event, without another value-tree allocation or clone.
- **Forwarded result imports**: `ImportRelease.prepare`. One cold
  outbox per session, then one batch and two exact position/delta arrays per
  capability-bearing forwarded result. The shared GC model requires both
  arrays. Values-only results allocate none of these. The answer payload owns
  the callback's original import retains, and final release links its prepared
  batch into the outbox without allocation.

  Live and ready batches together
  spend the inbound-answer count and retained-answer byte limits. Bytes stay
  charged through wire publication. Pressure preserves the batch for retry.
  Emission or teardown frees it. One nullable pointer adds eight bytes to a
  64-bit safe-mode Peer, four million bytes at 500,000 sessions.
- **Local promise registry**: `local_promise.Registry`. One cold box per
  session with local promise projections, plus one export position per
  projection, freed with the last projection or at teardown. Collection checks
  each projection's own roots there first and scans the answer tables only
  when some projection could be garbage, so a
  pending or wire-held projection never makes every partner release pay a
  partner-sized trace. One nullable pointer adds eight bytes to a 64-bit
  safe-mode Peer, four million bytes at 500,000 sessions.
- **Forwarded reply identity**: `ForwardedReply.prepare`. One entry in the existing
  resolver-purpose map, bounded by the export cap. The fresh local resolver
  binds the original answer's row stamp. It adds no reverse index or payload
  retain. Refusal, callback completion, resolver GC or teardown retires it.
- **Listener fire carriers**: `engine.Outbound.listener_fire`,
  `Session.store_stamp_counter`. POD carriers over the stored resolution or a
  live export's near fulfill. Zero payload copies.
  - Queue-time retains pin the payload's `near` exports across the
    queue-to-encode window against a legal partner `op:gc-exports`, which is
    why fire accounting cannot move to encode time.
  - Row identity stamps make a released-and-reused position leave the fire
    moot instead of shipping another row's payload.
  - Pinned by `test/engine/listener_fire_budget_test.zig`.
- **Outbound byte accounting**: `Peer.queuedOutboundBytes`. One machine word
  per peer, updated where the outbound queue takes or transfers frame ownership,
  so a byte-fed host's backpressure check is O(1) and re-walks no queued
  frame. At 500,000 sessions the fixed charge is about 4 MiB. The peer struct
  and warmed-state checks hold it.
- **Guaranteed projection settlement**: `Peer.settleAnswerTargetGuaranteed`.
  Lower in place (this path bypasses `send`'s chokepoint), move into the
  answer store, fire from the store.
  - Written exactly once, so a second settlement is refused. No clone on the
    single-store path.
  - A settlement whose carrier allocator or outbound pressure refuses commits
    the store and increments one `u32` deferred count on the Peer. Only while
    nonzero does `step` scan local promise projections for a deferred row.
  - Held by behavior tests, not a budget test.
- **Proxy fan-out**: `proxy_admission.foreignPromiseFulfill`,
  `passable_batches.stage`. One home `op:listen` is shared across recipients,
  never N listens. The Host lifts the fire once.
  - Each recipient owns one bounded materialization because its references,
    gives, and promise positions differ. Object occurrences mint one
    recipient-addressed give each. Promise occurrences share the existing
    home-listener machinery.
  - Admission owns one fixed terminal-break buffer and action seat per
    recipient, so projection, signing, entropy, or teardown failure cannot
    strand it.
  - Bounded by `Node.max_proxy_recipients` and the recipient queue cap.
  - The recipients' staging shares one arena per fire, reset between recipients
    under `steady_proxy_recipient_arena_bytes`, so a full fan-out pays one
    backing allocation, not one per recipient.
- **Inline Passable projection staging**: `Node.stageOutbound`,
  `budget.reserveInline`. One owned message waits for gift ids,
  shared promise listeners and recipient escrows.
  - No partial rewrite, deposit, proxy listener or recipient import is visible.
    Staged bytes and occurrences stay under the recipient's outbound waterline
    and queue cap. Deposits for one exporter are admitted together. Commit moves
    the message without another clone.
  - `Peer.publishAnswerRelease` owns a bounded POD carrier, including before
    staging completes. A release flag keeps `Peer` within its struct budget.
    Success transfers it to Session, and failure drops it. Public release copies
    no position array.
- **Projection anchors**: `pipeline.respondToProjection`. One dupe of the field name
  or tag, because the projection outlives the view that carried it. `op:index`
  dupes nothing. Bounded per answer by `max_listeners_per_target` (ADR-0004).
- **Local-delivery frame synthesis**: `pipeline.deliverDrainedCallLocally`. One
  synthesized frame, which the frame-based event model requires: a borrowed frame
  cannot carry a message that never arrived on the wire. Bounded by
  `max_local_deliveries`. Named, not measured.
- **Partner location and key arena**: the `start_session` arm of
  `session/apply.zig`, into `Session.key_arena`. Session tables are authoritative
  and outlive any frame, so the partner's session key and location bytes are
  duped in.
  - When decode supplies verbatim location bytes, **that one buffer is the sole
    owner and the designator is a relocated subslice of it**, not a second
    dupe. Owned-apply has no raw bytes and keeps a designator-only dupe.
  - Every byte-keyed table is O(1), not a `std.mem.eql` scan.
  - **A bump arena is the right owner only because those tables never remove a
    row**, which is why the FIFO-evicting `sturdyref_cache` and the
    individually-removed `pending_enlivens` keep their bytes on the gpa.
- **Sturdyref FIFO topology**: `sturdyref_cache.Entry` retains two inline row
  indexes per admitted cache row. No additional allocation or idle Session
  footprint. Dense removal repairs only relocated rows, bounded by the cache cap.
- **Own-side position slabs**: `session.PositionSlab` under `ExportTable`
  and `OutboundAnswerTable` (ADR-0038). One vector per table over the
  positions this session mints, growing by half plus one slot as `reserve`
  needs and to the exact index on an explicit install. A freed slot is the
  next minted, and no row is hashed. Each slab keeps a free-list head and a
  live count, sixteen bytes on `Peer` for the two. `OutboundAnswerTarget`
  carries the row stamp beside the position, eight bytes more than the
  position in every reader that outlives a turn: the queued resolve event
  (208), the vat's far listener key, and the Host's vow row (160). Pinned by
  `test/engine/footprint_budget_test.zig` and
  `test/session/position_slab_test.zig`.
- **Resolver purpose on the export row**: `ExportRow.purpose` (ADR-0038).
  Every export row is 48 bytes, pinned in `export_table.zig`: the count, the
  32-byte purpose union (`.none` on an ordinary export), and the cell's
  binding, with the cell rebuilt from the index. A resolver export adds no
  row to any table, and its answer row holds the export back. The
  purpose leaves with the row, so a retired resolver's tombstone lasts
  exactly as long as the partner's mention. Shortening dedup is one bool on
  the imported promise entry (`shortening_subscribed`), not a reverse row.
- **Shortening GC closure**: `expandGcExportReleases`. Rare outbound-GC
  scratch plus replacement position/delta slices keep edge-owned import retains
  in the same wire operation as the caller's release. They are recorded as the
  two releases they are: the caller's prefix through `recordSend`, the session's
  trailing closure through `recordSessionImportRelease`. Ordinary sends
  allocate nothing here.
- **Session-held import retains**: `ImportRow.session_held`. One word per
  import row. It names which of a row's retains the session releases itself (a
  linked V1.0 resolver's, a pending listener's, a stable shortening edge's), so
  a caller's release is bounded by `ImportTable.releasable` and the fire that
  later addresses the row finds it.
- **Sturdyref enliven dedup**: `Session.notePendingEnliven` (ADR-0007). One
  swissnum dupe per in-flight row, moved into the resolved cache on fulfillment.
  A full resolved cache evicts before insertion. An in-flight row reserves both
  cache structures before committing the fetch, so allocation failure refuses
  the enliven transaction instead of silently disabling dedup.
- **Owned Host enlivenment**: `Host.enlivenCapability` allocates one fixed-size
  operation from the caller's allocator, with an inline bounded failure message.
  - `enliven/group.zig` reserves one group, member, vow and answer-release
    carrier before admission. Followers keep their member and vow and retire the
    unused group reservation.
  - One Host-wide pending index adds no session storage, and the Host footprint
    test in `test/driver/core_host/admission_test.zig` pins its bytes.
  - The group owns the sole wire listener and GC carrier through the last
    observer or public pipeline handle. Each result owns its own retain. A
    temporary capability retain protects shared projection through the callback
    turn.
  - `HostRuntime.enliven` consumes the owned result directly, removing its
    cache-completion parking state. A parked row carries one recipient union,
    and its locator bytes retain their existing Host owner.
  - Cancellation releases observation storage without copying a result or
    allocating a GC carrier.
- **Freed export ranges**: `engine.Node.freed_export_bases`. Export ranges are a
  fixed budget, so a released session's range comes back and is re-handed
  oldest-first. Registration reserves the exact future return slot before the
  range becomes session authority, making release infallible under allocator
  pressure. No layer above keeps a session's base.
- **Canonical set and struct ordering**: `writeCanonicalSet`,
  `writeCanonicalStruct`, `writeHintDict`, `encodeArgumentSetList`,
  `Builder.finishCopying`. Sets encode each element once and sort the encodings,
  freeing the scratch before encode returns. Syrup dictionaries sort borrowed
  keys and iterator checkpoints through `canonical_collection.writeKeyed`, then
  emit each value directly. Its key comparison reproduces the encoded String
  order, including decimal length prefixes. Both codecs keep the first eight
  dictionary entries on the stack and spill larger ordering tables to the
  allocator, freed before return. The allocation budget tests hold a small
  dictionary to its one output allocation.
  - A Cap'n Proto set element snapshots its framed bytes because its builder
    stays live for the graft that follows.
  - An ordinary Cap'n Proto message copies none of its encoded bytes. The
    builder reserves the segment-table word ahead of the segment and
    `Builder.initial_words` ahead of the growth cliff, so `finishOwned` hands its
    one allocation to the frame.
  - The trim `finishOwned` ends on is in-place on the allocators glowcap ships
    against. One that cannot shrink there falls back to `std`'s copy.
- **Boxed handoff argument**: the handoff arm of `view.zig`'s
  `Argument.toOwned`. Boxed so the largest arm does not set the size of _every_
  `Argument`. `src/ocapn/model/mod.zig` asserts a comptime size ceiling for
  `Argument` and `Resolution`, so un-boxing fails the build.
- **Crypto fixed-width materialization**: `crypto.PeerKey.fromSlice`,
  `crypto.Signature.fromParts`. `std.crypto` takes fixed arrays and offers no
  allocator pattern. The wire has slices.
- **Give-location dialable form**: `handoff_gifter.exporterLocationForRecipient`.
  One decode-and-re-encode per give whose *onion* exporter hello carried
  `glowcap/*` profile hints and whose recipient is not known to be glowcap
  (ADR-0042). Every other give (every non-onion transport, every Goblins
  exporter) takes the null path allocation-free and embeds the verbatim hello
  bytes its receiver's withdrawal keying matches. The derivation lives at the
  declaration.
- **Handoff canonicalization**: one owned signing-domain buffer per certificate.
  An immediate withdrawal never owns the inbound tree. A Syrup-forwarded give
  carries its exact signed envelope, so receive bypasses typed hints. Cap'n
  Proto's lazy hints project into bounded scratch freed before return: once
  per certificate in `canonical.zig`, shared by both render passes, once
  per pass in `signing.writePeerLocatorRecord` when a decoded hinted locator
  is re-encoded (the one allocation the Syrup measure pass makes), and once
  in `encode_records.encodePeerLocator` on Cap'n Proto.
- **Gift registry**: `engine.bootstrap.gifts.GiftRegistry`. A lazy per-`Peer`
  owner keeps rows on the gpa with precise frees, **never a bump arena**, which
  cannot reclaim an overwritten row and would leak every re-deposit.
  - Whole-row requested bytes (map key/slice, payload tag, opaque id,
    provenance, and variable owned reference data) are admitted before
    allocation or authority adoption, then charged exactly through replacement,
    withdrawal, and teardown.
  - The outbound message is built and queued before an infallible commit removes
    the gift, so queue OOM leaves it retryable.
  - **Because a consumed row is gone, the row count _is_ the live-gift count**,
    so `max_deposited_gifts` needs no parallel counter.
    `max_deposited_gift_bytes` owns cumulative retained size.
- **Swissnum miss diagnostic**: `resolveForSwissnum` (`engine/bootstrap.zig`).
  One string dupe on the unknown-name break path, because the diagnostic must
  outlive the resolving frame and `send` frees the resolution it rides in. The
  fulfill arm is POD and allocates nothing.
- **Parked withdraw**: `Peer.pending_withdraws` (ADR-0039). One compact verified
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

- **Materialized views**: `Port.sendDelivery`. Views to a local actor, or
  to a far one when session validation counted a reference in them, are
  materialized once into the vat's allocator and freed when the queue or
  the wire has taken them, because the queue retains owned arguments and
  the session rewrites a reference in place. A handler's turn has an arena
  and takes `Turn.sendDelivery`, so a local send from a turn pays no free.
- **Opaque ingress custody**: `OpaqueMessage` charges its requested bytes before
  guarded copy admission.
  - `local_delivery.Input.copy` materializes verb, Value spines/leaves and
    keeper retains in the existing queue arena.
  - The queued target and every capability occurrence outlive observer
    cancellation. Callback observations acquire independent retains, and
    projection refusal releases them before callback entry.
  - Consuming retirement prevents repeated cleanup across dispatch, rollback,
    ingress cancellation and teardown.
  - Footprint tests pin the queue row size and turns per chunk
    (`test/actors/vat_footprint_budget_test.zig`).
- **Archive-neutral actor callbacks**: `HandlerFailure` carries immutable
  archive-owned text and scalar error-domain metadata on the call stack.
  - The producing archive catches the error. Receivers recover a typed ordinal
    only in that compilation. Nothing allocates, copies or traverses.
  - `OpaqueMessage.VTable` adds one constant protocol identity, independent of
    its address. `Vat.turn_failure` retains an optional text slice for
    rollback. Sessions and queue rows gain none.
  - The Host footprint test pins the added bytes.
- **Owning local completion**: `local_delivery.Producer` and `VowRow` sizes
  are pinned in `test/driver/core_host/local_delivery_test.zig`. The reply
  destination tag adds one inline word.
  - Warm admission allocates those two owners. `Host.Call` separately allocates
    its operation (size pinned in the same test) and exactly the configured reply
    backing.
  - Reply preparation copies Value spines/leaves and acquires occurrence retains
    before state replacement or resolver consumption. `completion.retainValue`
    uses the stable Value as its rollback receipt, without another inventory
    allocation or capability-count walk.
  - `ReplyAllocator` is a synchronous stack proxy over the fixed backing. Its
    refusal latch distinguishes reply capacity from Host heap pressure without
    another allocation, copy, walk or persistent field.
  - Local forwarding reuses that Producer, row and reply backing. Each hop owns a
    copied input and the existing forwarding context.
  - Measurements cover caller demand, warm admission, terminal live bytes and
    heterogeneous logical copy demand.
- **Public local reply**: `local_completion.Reply` embeds the Producer in one
  allocation (size pinned in `test/driver/core_host/local_effects_test.zig`), plus
  the existing public vow row.
  - One arena materializes trusted output and moves into the reserved Host
    action. Preparation/publication and queue adoption preserve the same
    pointers.
  - A child queued inside a running parent also needs the existing overlapping
    queue chunk and its backing: measured warm send/tell admission costs
    four/three allocations. Tell uses only its discard Producer and queued input,
    with no Call, Host vow row or reply allocation.
  - Constructor refusal, deferred preparation retry and aggregate retirement pin
    custody.
- **Foreign owning answer transfer**: `foreign_forward.ForeignForward` embeds
  the existing `ForwardContext`, actual peer and original Producer custody in one
  box whose size `foreign_forward.zig` asserts. The observed wire vow owns that
  box and answer-release reservation. `prepareWire` projects once into the
  original fixed reply buffer. Canceled observers discard wire occurrences. No
  child Call or resolver pair is created. Tests pin caller allocation count and
  terminal custody.
- **Ingress clone**: `Vat.send` / `Vat.tell`'s local arm, over
  `model.cloneArgumentSlice`. The far arm's contract inside one vat: a queued
  turn runs at a later `drive` whose first outermost turn resets the very arena
  the handler built its args in. `model.measureArgumentSliceOwnedBytes` walks the
  same shape first, so admission refuses a limit **before any queue mutation**.
- **Far notifications**: `AnswerCell.application_notification_consumed` guards
  one-shot observation within the `AnswerCell` row that
  `test/session/answers_slot_test.zig` pins. `Port.far_listeners` uses dense
  indexed storage: its larger header supports O(1) bulk removal while other
  listeners remain cancellable. Bulk failure frees the store without allocating.
  A Port cutoff refuses old vows, with no completed-answer map.
- **Settle clones**: `Vat.settle_arena`. Each defends two hazards, which is why
  it can be re-homed but never deleted: a listener may open a top-level turn
  whose depth-0 reset frees a turn-arena value mid-call, and the value may borrow
  the settling actor's own state, which a listener-run turn can mutate or
  `become`-free. Depth-guarded, so it covers a nested drive and a far listener
  re-entering `serve` through a driver pump.
- **Far send verb splice**: `farDeliverTo`. Stack buffer to seven args, then one
  immediately-freed gpa spine, **never the turn arena, because the path is
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
- **State boxes**: `StateBox`, `releaseBox`, `ensureUnshared` (ADR-0015). One
  refcounted heap block per actor, so `Vat.snapshot` shares boxes at zero bytes
  copied and a non-snapshotting actor pays one pointer indirection. Deleting the
  layer forces an eager O(total-mutable-bytes) snapshot copy.
- **Retired boxes**: `Vat.retired_boxes`. A `become` install swaps the cell's
  box but its reference falls at the next outermost turn, because an _earlier_ <!-- status-allow: workflow sequence -->
  frame of the same actor may already have returned a reply borrowing it, leaving
  no live frame to copy it.
  - Registration escrows one pointer slot per live actor so last-root release
    and teardown never allocate.
  - `stageBecome` additionally reserves one slot per open frame, not per stage.
  - Burst backing is replaced transactionally at the next outer-turn boundary,
    while the live-actor escrow remains.
- **Forwarding callback identity**: `Vat.forward_listener` retains one function
  pointer per Vat, shared by every owned forwarding context. The C archives
  publish and classify through that exact identity, so teardown and iterative
  settlement do not depend on process-wide identity of compiled private
  functions. The Host footprint check pins the eight-byte charge.
  Listeners and sessions gain no fields or allocations.
- **Turn-forward context**: `reserveForward` owns one `ForwardContext` per
  answered eventual forward. Tells allocate none. Local chains settle iteratively.
  Settlement or `freeOwnedForwardContexts` frees it. `forwardTurnVow` also owns a
  `ForwardRegistration` (size asserted at its declaration) until commit or abort,
  so an existing vow loses only the failed turn's listener. Other forwarding
  contexts gain no fields.
- **Dynamic turn break**: `Turn.breakWith` copies a queued call's diagnostic
  into the turn arena before foreign callback storage expires. `settleLocal`
  copies it into its depth-guarded settle arena before listener reentry.
- **Actor roots**: one `u32` per row (ADR-0014). Each relationship holds one
  root, transferred at the seam that owns it. Root zero retires the row past any
  running frame and parks the box on the retirement capacity registration
  escrowed before the actor became visible.
- **Persistent map nodes**: `collections.PersistentMap` (ADR-0015). O(log n)
  fresh nodes per write with refcounted structural sharing. An immutable trie is
  acyclic, so the count frees with no collector, and retains happen only after
  every allocation in a rebuild succeeds. Rebuilding whole makes `become`
  O(size).

### Transports, loops, and streams

The [transport inventory](references/transports.md) owns spill, loop,
resident, and stream costs.

### Host tier

The [Host inventory](references/host.md) owns runtime handles, value projection,
session routing, and capability custody costs.

### Named deferred costs

These costs are named, not forbidden. Relocating one does not delete it, so
the name stays here.

- **Binding dial OS-connect string**: each binding decodes `host` and
  `addresses` once after `glowcap_host_plan_dial`, because the OS connect API
  needs a language string. A second rematerialize of the same view through
  `readMemory` / `string_at` / `bytes<-c` is forbidden.
- **Rust received capability custody**: `gc::owned_guard` allocates one shared
  guard for each owned C occurrence, including local callback observations.
  Clones share that guard. Independently received equal ids keep distinct
  C retains. Its declaration owns the lifetime and cycle derivation.
- **Binding outbound flush copy**: TypeScript, Python, and Racket copy
  managed-frame bytes and release before the async write. Rust holds the frame
  across it. Language and lifetime forced: no change without a hold-across-await
  proof. The C descriptor keeps its Zig `Frame` owner inline and allocates
  nothing. Each copying binding reuses one descriptor/prefix scratch set per
  serialized Session drain, so only the named payload copy remains per frame.
- **TypeScript FFI connection write copy**: `AsyncFfiWriteQueue` snapshots a
  caller-owned frame before off-thread TCP, inproc, or onion FFI can borrow it.
  No single frame or admitted set may cross the connection's frame-scale byte
  waterline. Later writes are refused until ownership retires, and a separate
  <!-- value ../../../bindings/ts/runtime/transport/ffi_frame.ts maxPendingWrites -->16<!-- /value -->-write cap keeps zero-length calls from retaining an unbounded promise
  chain.
- **Racket inbound `pin-immobile`**: every `feed_bytes` path pins the buffer
  into collector-immobile memory first. The tail lives in the core session, so no
  binding-side coalesce rides on top.
- **Wasm linear-memory boundary**: `bindings/ts/web/adapter.ts` (ADR-0034).
  JavaScript cannot lend wasm a view, so every buffer argument pays one copy in
  and each `outBuffers`-marked out-parameter one copy back. **Do not delete the
  memoized re-stage's resync as an optimization**. Staged copies retire two
  outermost-call windows later, because a call's returned views alias its staged
  inputs.

The [Loam inventory](references/loam.md) owns durable storage, hosted calls and
C/Rust projection costs. The [Rooms inventory](references/rooms.md) owns
managed session execution and archive retention costs.
