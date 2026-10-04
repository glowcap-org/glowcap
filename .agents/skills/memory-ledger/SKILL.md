---
name: memory-ledger
description: "Use when adding, deleting, moving, or renaming an allocation or copy on the wire path, or a symbol a ledger entry names: the inventory of every named cost and the declaration that owns its derivation."
---

# glowcap — Memory Ledger

The [memory rule](../../rules/memory.md) says when a wire-path allocation or copy may
exist at all: forbidden by default, named only after a full derivation,
measured when deleted. This file is the inventory of the ones that earned a
name.

## The ledger

Every allocation and copy that survived that derivation, one line each.

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
  Before mutation, `ResolutionStorePlan` admits replacement delta against an
  independent durable byte cap; GC, promise retirement, and teardown release
  it. `GlowcapSessionLimitOptions` and every binding's named counterpart expose
  that cap independently from transient outbound pressure. Zero copies and no
  added Peer footprint, pinned by
  `test/engine/resolve_alloc_budget_test.zig` and
  `test/engine/node/answer_settlement_test.zig`.
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
- **Proxy fan-out** — `proxy_admission.foreignPromiseFulfill`,
  `passable_batches.stage`. One home `op:listen` is shared across recipients,
  never N listens. The Host lifts the fire once; each recipient owns one bounded
  materialization because its references, gives, and promise positions differ.
  Admission owns one fixed terminal-break buffer and action seat per recipient,
  so projection, signing, entropy, or teardown failure cannot strand it.
  Object occurrences mint one recipient-addressed give each; promise
  occurrences share the existing home-listener machinery. Bounded by
  `Node.max_proxy_recipients` and the recipient queue cap. The recipients'
  staging shares one arena per fire, reset between recipients under
  `steady_proxy_recipient_arena_bytes`, so a full fan-out pays one backing
  allocation rather than one per recipient.
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
  in the same wire operation as the caller's release, recorded as the two
  releases they are: the caller's prefix through `recordSend`, the session's
  trailing closure through `recordSessionImportRelease`. Ordinary sends
  allocate nothing here.
- **Session-held import retains** — `ImportRow.session_held`. One word per
  import row, in place of the 16-byte cell every import row used to carry for
  a value that was always its own position. It names which of a row's retains
  the session releases itself (a linked V1.0 resolver's, a pending listener's,
  a stable shortening edge's), so a caller's release is bounded by
  `ImportTable.releasable` and the fire that later addresses the row finds it.
- **Sturdyref enliven dedup** — `Session.notePendingEnliven` (ADR-0012). One
  swissnum dupe per in-flight row, moved into the resolved cache on fulfillment.
  A full resolved cache evicts before insertion; an in-flight row reserves both
  cache structures before committing the fetch, so allocation failure refuses
  the enliven transaction rather than silently disabling dedup.
- **Owned Host enlivenment** — `Host.enlivenCapability` allocates one fixed-size
  operation from the caller's allocator, with an inline bounded failure message.
  It reuses the existing vow/cache bridge and reserves observer answer-release
  capacity before wire admission. A parked row carries one recipient union;
  its locator bytes retain their existing Host owner. Cancellation releases
  observation storage without copying a result or allocating a GC carrier.
- **Freed export ranges** — `engine.Node.freed_export_bases`. Export ranges are a
  fixed budget, so a released session's range comes back and is re-handed
  oldest-first. Registration reserves the exact future return slot before the
  range becomes session authority, making release infallible under allocator
  pressure; no layer above keeps a session's base.
- **Canonical set and struct ordering** — `writeCanonicalSet`,
  `writeCanonicalStruct`, `writeHintDict`, `encodeArgumentSetList`,
  `Builder.finishCopying`. Encode each element once and sort the encodings, turn
  scratch freed before encode returns. **Sorting on model values instead lets two
  encoders disagree; the bytes are the only order both sides reproduce.** A Cap'n
  Proto set element snapshots its framed bytes because its builder stays live for
  the graft that follows. An ordinary Cap'n Proto message copies none of its
  encoded bytes: the builder reserves the segment-table word ahead of the
  segment and `Builder.initial_words` ahead of the growth cliff, so `finishOwned`
  hands its one allocation to the frame. The trim `finishOwned` ends on is
  in-place on the allocators glowcap ships against; one that cannot shrink there
  falls back to `std`'s copy, the cost this replaced.
- **Boxed handoff argument** — the handoff arm of `view.zig`'s
  `Argument.toOwned`. Boxed so the largest arm does not set the size of _every_
  `Argument`; `src/ocapn/model/mod.zig` asserts 40 bytes for `Argument` and 48
  for `Resolution` at comptime, so un-boxing fails the build.
- **Crypto fixed-width materialization** — `crypto.PeerKey.fromSlice`,
  `crypto.Signature.fromParts`. `std.crypto` takes fixed arrays and offers no
  allocator pattern; the wire has slices.
- **Give-location dialable form** — `handoff_gifter.exporterLocationForRecipient`.
  One decode-and-re-encode per give whose *onion* exporter hello carried
  `glowcap/*` profile hints and whose recipient is not known to be glowcap
  (ADR-0118); every other give — every non-onion transport, every Goblins
  exporter — takes the null path allocation-free and embeds the verbatim
  hello bytes its receiver's withdrawal keying matches. The derivation lives
  at the declaration.
- **Handoff canonicalization** — one owned signing-domain buffer per certificate.
  An immediate withdrawal never owns the inbound tree. A Syrup-forwarded give
  carries its exact signed envelope, so receive bypasses typed hints; Cap'n
  Proto's lazy hints project into bounded scratch freed before return.
- **Gift registry** — `engine.bootstrap.gifts.GiftRegistry`. A lazy per-`Peer`
  owner keeps rows on the gpa with precise frees, **never a bump arena**, which
  cannot reclaim an overwritten row and would leak every re-deposit. Whole-row
  requested bytes — map key/slice, payload tag, opaque id, provenance, and
  variable owned reference data — are admitted before allocation or authority
  adoption, then charged exactly through replacement, withdrawal, and teardown.
  The outbound message is built and queued before an infallible commit removes
  the gift, so queue OOM leaves it retryable. **Because a consumed row is gone,
  the row count _is_ the live-gift count**, so `max_deposited_gifts` needs no
  parallel counter; `max_deposited_gift_bytes` owns cumulative retained size.
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
  authority. **The fixed-size 128-bit BLAKE3 gift tag is what keeps a
  partner-chosen gift-id length out of coordination state**; signed bytes stay
  the authority, so a collision costs one bounded retry. Deposit and close
  notification allocate nothing after the first group.
- **Redeem dial parts** — `Node.stageDial`. Parse the exporter URI once
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
- **Reply sever on install** — `callWithOrigin`. Clones the reply onto the turn arena
  when a `become` will install at this frame's unwind, because the install frees
  the box the reply may borrow. **The gate is the install, not this frame's own
  staging.** An ordinary near-call still returns its reply borrowed, and `serve`
  needs no clone at all, because it copies onto the wire inside the turn window.
- **Moved replies** — `Turn.moveOut` / `moveOutString`, `Vat.moved_replies`. A
  handler that owns its reply's bytes _transfers_ them instead of paying the
  sever, and `callWithOrigin` skips the sever only on pointer identity with that
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
- **Turn-forward context** — `reserveForward`. One gpa `ForwardContext` per
  answered eventual forward, local or wire; tells allocate none. Local answer
  chains settle iteratively without another value clone. Listener settlement or
  `freeOwnedForwardContexts` reclaims the context.
- **Dynamic turn break** — `Turn.breakWith` copies a queued call's diagnostic
  into the turn arena before foreign callback storage expires. `settleLocal`
  copies it into its depth-guarded settle arena before listener reentry.
- **Actor roots** — one `u32` per row (ADR-0101). Each relationship holds one
  root, transferred at the seam that owns it; root zero retires the row past any
  running frame and parks the box on the retirement capacity registration
  escrowed before the actor became visible.
- **Persistent map nodes** — `collections.PersistentMap` (ADR-0061). O(log n)
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
- **Readiness pending-operation rows:** `epoll.Backend.pending` and
  `kqueue.Backend.pending`. One compact row joins each descriptor with its
  armed read and write completion identities. The map grows when concurrent
  armed descriptors reach a new peak, then retains that capacity so steady
  re-arm is allocation-free.
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
  Iroh's inbound twin, `nb_reader`, appends each QUIC chunk once into the
  connection's bounded inbound buffer and `conn_try_read` drains it by
  advancing an offset, compacting only when the consumed prefix reaches the
  pending bytes, so the buffer tracks the bounded pending count and never the
  bytes ever received; it too shrinks back to `NB_STEADY_BYTES` once drained.
  Iroh retains at most one `NB_STEADY_BYTES` spare after a drained burst; relay
  send staging retains at most `RelayOptions.send_staging_bytes`, 4 KiB by
  default including the frame header. A larger override is an explicit
  per-connection memory commitment, not a frame-admission limit. WSS copies
  ciphertext once into its fixed TLS record window and writes decrypted bytes
  directly into that same WebSocket staging path; refused TLS sends retry from
  allocation-free intrusive links in bounded turns, never by cloning the
  application payload or adding a per-connection thread.
- **Wrapped-backend ready-queue reservation** — the onion, noise, and
  keyed-relay completion adapters (`ReadyQueue.ensureUnusedCapacity` before
  each poll turn). Consuming one inner completion may terminate a connection
  whose external connect, recv, and send seats each owe a record, and onion's
  close handshake owes one more, so each adapter reserves that whole fan-out
  (three or four records per inner completion, times the 256-record turn)
  before it takes any inner completion from the backend it wraps; an
  already-earned record is never lost to a refused reservation. The queue keeps
  that peak, about 36 KiB (48 KiB for onion) per adapter, for the backend's
  life: `appendAssumeCapacity` is what makes fan-out infallible mid-turn, and a
  shrinking queue would give that back. Stacked adapters each hold their own.
- **iroh provider connection-id table** — `MultiplexedAdapter`
  (`src/net/transport/iroh/multiplexed.zig`, ADR-0184). One POD row per live
  loop connection, mapping the sidecar's stable id to its handle, because
  drained records carry ids while the sidecar verbs take handles. Rows enter
  at `finishConnect` or `finishAccept`, free precisely at `closeConnection`, and adapter teardown
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
  Locally gathered ICE candidates are retained only in that peer's signaling
  queue, capped at 256 records and 64 KiB total text; overflow terminalizes the
  peer as a transport failure instead of growing control-plane memory.
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
  signaling control state, not session bytes, but remain peer-influenced
  when the signaling capability crosses a network.
- **Pinned stream wrapper** — `netlayer_support.PinnedRawStream` for a raw
  socket connection (`tcp`, `onion`) and `netlayer_support.PinnedStream` for a
  shim-sourced one (`inproc`, `IrohStream`) (ADR-0043, ADR-0055).
  `std.Io.Reader`'s vtable recovers its concrete reader from `&interface` by
  field offset, so the reader and writer need a stable address outside the
  by-value `Connection`. Storing them inline dangles the moment the connection
  moves. Two shells because the sources differ in kind: a raw socket already
  owns std's reader and writer, and shimming it would add a second buffer and
  a copy. Blocking path only; the loop builds no `Connection`.
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
- **Native accept queue** — `driver.Server.accepted` (ADR-0184). One ring of
  Session pointers reserved at construction, bounded with handshake reservations
  by `max_pending_opens`. Wrappers allocate at publication and transfer to the
  caller at accept; the queue allocates nothing and copies no payloads in a turn.
- **Lower and lift boundary** — `driver.Session` (ADR-0096). One
  `Session.verb_scratch` arena on the way down (spines only; leaves stay
  borrowed), reset at each verb's entry under `steady_verb_scratch_bytes` the
  way the C host tier resets its own, so a steady stream of verbs allocates
  nothing after the first; and the caller's arena on the way up, with
  capability rows under rollback receipts. **The lift
  aliases the settle capture rather than re-cloning, which is why `Reply` is
  arena-only and carries no `deinit`.**
- **Settle capture** — one `model.cloneArgument` or broken-reason dupe per
  blocking wait (`BlockingSession.call`, `driver.Promise.settle`, `SettleCapture`).
  Severs the turn-borrowed resolution so the returned `Settled` outlives the
  drive. `fetch` and `enliven` stay allocation-free.
- **Unobserved vow completion** — `queueVowCompletion` materializes one owned
  Host Value with one retain per capability occurrence (ADR-0177). Bytes and
  spines copy once into its arena; scalar and cached capability results need no
  arena backing. Eight lift receipts stay inline; spill uses temporary Host
  storage freed before publication. Actions move through drains and parked
  tables without another clone. Their inline arena state adds 16 bytes per
  action (64 → 80) and per Host (2,344 → 2,360 under safety); sessions gain none.
  Projection acquires consumer retains without scratch allocation and rolls
  back a failed prefix through the stable tree. `completion_test.zig` covers
  allocation refusal and the spill boundary; `admission_test.zig` pins sizes.
  Every mint reserves its FIFO slot, so publication cannot strand a completion.
- **Settle mailbox** — `driver.SettleMailbox` (ADR-0102). Fixed slots at init, so
  a worker's `post` allocates nothing; one boundary clone into the slot's arena,
  refusing `ValueTooLarge` and `MailboxFull`. Backpressure, never growth.
- **Loop-archive dial and events** — `glowcap_driver_dial`,
  `glowcap_driver_next_event` (ADR-0112). A dial projects the borrowed locator
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
- **Host session indexes** — `Host.partner_by_side`, `Host.dialed_by_target`
  (ADR-0012). O(1) dial and partner-key refusal at the 500k tier, on the gpa with
  precise frees, because rows leave individually.
- **Session close timing** — `Host.session_close_timing` (ADR-0114). One gpa map
  row per finite-grace session close, removed at `Host.markSessionTerminating`
  or tolerantly at `freeSessionShell`. Cancel and unbounded finishes pay
  nothing, so an open session stores no deadline; the timing lives out of line
  for exactly that reason, argued at the declaration.
- **Parked Node actions** — `Host.parked_node_actions` (ADR-0145). One gpa
  row per recipient whose outbound pressure refused a Node action, holding
  the actions moved off the shared queue with their payload intact
  (`Node.parkPeekedAction`), so one partner's flow control holds back only
  what is bound for it. The seat an action returns to is promised before it
  leaves the queue, so every fallible step precedes the take and the return
  through `Node.pushParked`, on the next take of that recipient's outbound
  bytes or at its release, never allocates. Out of line, so a session under
  no pressure pays nothing.
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
  `addresses` once after `glowcap_host_plan_dial`, because the OS connect API
  needs a language string. A second rematerialize of the same view through
  `readMemory` / `string_at` / `bytes<-c` is forbidden.
- **Binding outbound flush copy** — TypeScript, Python, and Racket copy
  managed-frame bytes and release before the async write; Rust holds the frame
  across it. Language and lifetime forced: no change without a hold-across-await
  proof. The C descriptor keeps its native `Frame` owner inline and allocates
  nothing; each copying binding reuses one descriptor/prefix scratch set per
  serialized Session drain, so only the named payload copy remains per frame.
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

The [Loam inventory](references/loam.md) owns durable storage, hosted calls and
C/Rust projection costs.
