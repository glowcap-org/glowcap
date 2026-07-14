---
description: "Zig pancake memory and frame ownership: owned transfer, bounded borrow, explicit test-only copies."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h
---

# pancake — Memory and Frame Ownership

## Frame Contract

- `Frame` owns wire bytes.
- `FrameView` borrows wire bytes for a bounded call.
- `FrameShape.byte` means ordinary byte storage.
- `FrameShape.word` means word-aligned storage: pointer aligned to 8 and byte
  length divisible by 8.

## Copy Budget

Production paths use owned transfer or bounded borrow:

- `Frame.initOwned` adopts storage without copying and tracks the allocation
  alignment used to free it. Allocation alignment is separate from `shape`, so a
  byte frame may be over-aligned and still frees with its true allocation
  metadata.
- `Frame.view` borrows without allocation.
- `Peer.send(Message)` takes ownership and moves the message into the outbound
  queue. This is the canonical, copy-free path.
- `Peer.sendCopying(Message)` names the one boundary copy over `send`, for
  callers that hold borrowed or static message data they keep owning.
- `engine.pipeline.decomposeOutboundDeliver` splits a multi-hop pipelined
  deliver into single-hop links by _moving_ each path step's payload into its
  own message and freeing only the emptied `path.ops` backing slice. This
  repartitions the message spine; it does not copy payloads. The one allocation
  is the `[]Message` chain container. The drain side allocates no container at
  all: a drained pipelined call whose target resolved to _another_ promise
  moves one message at a time into `Session.requeuePipelinedCall`, which
  appends it directly (freeing it on refusal).
- `Peer.feedOwned(Frame)` transfers ownership for queued dispatch, consuming
  the frame on every outcome (released here if queueing fails).
- `Peer.recvBorrowed(FrameView)` dispatches during the call and retains no wire
  borrow.
- `Peer.emitAbortForError` handles a dispatch failure — an inbound refusal or a
  `step` drain/encode failure — by encoding a fresh outbound `op:abort` frame
  straight onto `outbound`, bypassing `recordSend`. Aborts are always admitted
  because the session is being torn down. The abort's diagnostic is a static
  `[]const u8` borrowed by encode, so there is no message clone. This path is
  best-effort: an encode or append failure is swallowed so the original dispatch
  error is never masked, but the session still closes when the
  `abort_projection` requires it.
- Test-support frame copy helpers (`test/support/frame.zig`, e.g.
  `copyFromBorrowed`) materialize borrowed wire bytes for assertions; production
  paths use owned transfer or bounded borrow instead.

Copy helpers belong in `test/support`, not production modules.

## Load-bearing allocations

Each allocation or copy below was scrutinized against the rule that a copy is a
design event: forbid it, name it, or measure it. Each one is required, and this
section names the contract that requires it. Do not "optimize" one away without
re-deriving that contract. Forbidding is the default verdict, not naming, see
the [prerelease posture](prerelease.md): re-derive a copy against the _full_
option set (a single durable owner the consumer already reads through can hold
the value, leaving the transient carrier only a key) before it earns a slot
here.

- **Outbound boundary copy: `Peer.sendCopying` into `model.cloneMessage`.** The
  outbound queue _owns_ messages until `step` encodes them (encode is deferred
  to `step`). The handshake / handoff drivers and the conformance harness feed
  _borrowed_, fixed-array, or static input (a `KeyPair`'s `[32]u8`, a
  caller-owned `HandoffGive`, a literal abort reason). An owning queue plus
  borrowed input requires exactly one copy. The spine moves through `Peer.send`;
  this is the one named boundary copy. Deleting it only relocates the same dupes
  into each driver, which is worse because the copies become scattered and
  duplicate `clonePeerLocator`.
- **Actor-local eventual-send boundary copy: `Vat.send` / `Vat.tell`'s local arm
  into the vat's `queue_arena`.** Actor-local, not wire-path: this is the far
  path's `Peer.sendCopying` contract replayed inside one vat. A queued local
  turn runs at the next `drive`, whose first outermost turn resets the turn
  arena — the very arena the documented handler pattern builds outgoing args in
  — so an owning queue plus borrowed input again requires exactly one copy. The
  clone (verb plus deep args, via `model.cloneArgumentSlice`) lands in one
  vat-owned bump arena and dies with the queue: one bounded reset
  (`retain_with_limit` at the vat's declared steady bytes, see the footprint
  budget below) when the outermost `drive` has fully drained it (nested drives
  leave it alone), so steady capacity amortizes, nothing is freed per message,
  and a burst's capacity is returned instead of pinned. The settle
  side pays the mirror-image copy, and it is arena-homed on both paths. Each
  settle clone defends two hazards: a listener may open a top-level turn
  (`near` or `drive`) whose depth-0 turn-arena reset would free a turn-arena
  value mid-call, and the value may borrow the settling actor's own mutable
  state, which a listener-run turn can mutate or `become`-free under the
  borrow — so the clone can be re-homed, never deleted. `Vat.settleLocal`
  clones the one fulfilled argument into the same `queue_arena`: it runs only
  inside `drive`, and that arena resets only when the outermost `drive` has
  fully drained, which cannot happen while the listener is still on that
  drive's stack. `Vat.serve`'s far-resolve arm clones into a dedicated
  `settle_arena` instead, reset when its `settle_depth` guard returns to zero
  (a far listener can re-enter `serve` through a driver pump,
  `BlockingSession.step` → `drainEvents`); the queue arena is unsafe there
  because `serve` runs outside any drive, so a listener-opened `drive` is
  *outermost* and its full-drain reset would free the value mid-call. The far
  send's verb-splice scratch is no longer a per-send allocation at common
  arity: `farDeliverTo` splices `[verb, args…]` in a stack buffer up to seven
  args and falls back to one immediately-freed gpa spine only above that
  (never the turn arena — the path is callable at depth 0, where an arena
  bump would pin until the next outermost turn). One more copy guards the same
  seam from the other side: when a `become` will *install at this frame's
  unwind* — the actor's outermost frame, with a become staged by this frame or
  promoted by an inner reentrant one — `callLocal` clones the reply onto the
  turn arena before promoting, because the install frees the actor's old state
  box as the call returns and the reply may borrow that state. The gate is the
  install, not this frame's own staging: an inner frame's become with no outer
  stage still frees the box at the outer unwind, and an inner frame itself
  (whose unwind installs nothing) never pays the copy. The clone stays valid
  for the reply's documented lifetime (the next outermost turn), and it is paid
  only when an install actually lands at the returning frame — an ordinary
  near-call still returns its reply borrowed. `serve` needs no such clone: it
  copies the reply onto the wire inside the turn window, before the box is
  freed. A mutable
  handler that owns its reply's bytes can skip the sever entirely by
  *transferring* them: `Turn.moveOut` (or `moveOutString`, the string arm of
  the same mechanism) clears the state field and hands the buffer to the vat
  (`Vat.moved_replies`, freed when the next outermost turn
  begins — the borrowed reply's exact lifetime), so the reply outlives the box
  with no copy; `callLocal` skips the sever only when the returned bytes are,
  by pointer identity, one of the allocations that turn moved (a scan of the
  turn's own moves, O(1) in practice), so a reply borrowing any *other*
  state is still severed.
- **Turn-forward context: one gpa block per forwarded turn that carries an
  answer (`Vat.forwardTurn`).** A `Turn.forward` whose turn answers the wire
  parks a heap `ForwardContext` so the forwarded send's listener can settle the
  original answer when it fires; freed when that listener fires, or swept at
  teardown (`freeOwnedForwardContexts`). Bounded by the application's own
  outstanding forwards. The transient class rides with it: `serve`'s give arm
  materializes one exporter-locator URI on the gpa for the duration of the
  projection and frees it in scope.
- **Vat local time-travel: refcounted state boxes, copy-on-write clone, and
  functional `become` (ADR-0060).** Actor-layer, off the wire path, and off by
  default. Each actor's state lives in one heap block headed by a `StateBox`
  carrying a non-atomic refcount (header and state are a single allocation,
  freed as one through `releaseBox`); `Vat.snapshot` shares those boxes (one
  refcount bump per actor, zero
  bytes copied, O(objects), Goblins's spine-copy shape), so a non-snapshotting
  actor's box stays `refs == 1` and pays only one pointer indirection per turn.
  Two opt-in writes close the share: a mutable actor's `clone` deep-copies a
  _shared_ box once, the first time a turn would mutate it (`ensureUnshared`),
  and a persistent actor's `become` allocates one fresh box per accepted turn
  and installs it at turn end (releasing the old live ref; a handler error frees
  the staged box instead). All three are bounded by the application's own actor
  graph and freed through the single `releaseBox` chokepoint when the last
  reference — live cell or snapshot — drops. Deleting the box layer forces an
  eager O(total-mutable-bytes) snapshot copy, the exact gap this design removes.
- **Persistent map nodes: refcounted HAMT, path-copy update (ADR-0061).**
  `persistent.PersistentMap` allocates O(log n) fresh trie nodes per `put`/
  `remove` and shares every untouched subtree by bumping its node's non-atomic
  refcount; an immutable trie is acyclic, so the count frees correctly with no
  collector. Retains happen only after every allocation in a rebuild succeeds,
  so an out-of-memory mid-build over-counts nothing. Actor-support for a
  persistent actor's incremental `become`, bounded by the map the application
  builds, and freed when the last version or snapshot holding a node drops it.
  Rebuilding the whole value each turn instead would make `become` O(size).
- **Bounded inbound spill: `net.Spill` (ADR-0041).** Read buffers size the
  steady state, so an admissible frame larger than the read buffer pays one
  extra bounded copy (read buffer into spill) and one allocation per oversize
  burst, freed when the spill drains. The fast path (frame fits the buffer)
  stays a zero-copy borrow with no allocation. Boundedness is the codec's
  cap-during-scan verdict plus a defensive incomplete-at-cap mirror in each
  consumer. Deleting this relocates the cost into `max_frame_bytes`-sized
  per-connection read buffers, which is the exact scaling problem ADR-0041
  removed.
- **Shared read-buffer pool and the tail-to-spill copy (ADR-0054).** The
  completion loop's read buffers are a backend-owned shared pool
  (`Options.read_buffers`, default 256, each 16 KiB; io_uring provided buffers),
  so an idle connection holds zero read-buffer bytes. A recv completion's bytes
  are a bounded borrow the loop consumes before recycling: whole frames apply
  zero-copy from the pool view, and a partial frame tail pays one bounded copy
  into the connection's ADR-0041 spill, freed on drain. While a spill is
  active, whole frames arriving behind the in-flight frame's completion are
  absorbed into the spill for that episode too — the zero-copy claim is scoped
  to spill-inactive. That tail copy is the
  named price of sharing: the old per-connection buffer kept a tail in place for
  free, at 16 KiB times every live connection. Deleting the pool reopens the
  per-connection buffer floor (about 7.6 GiB at 500k); deleting the tail copy
  would mean parsing across recycled storage, which is a lifetime bug, not a
  saving.
- **Bounded outbound queue: the completion loop's per-connection `front`/`back`
  pair (ADR-0042).** The loop cannot block on a send, so an outbound frame's
  bytes are copied once into the connection's queue and the frame is freed. The
  queue is what a completion write borrows while the loop keeps running, and
  that borrow is why the queue is two buffers: a submitted write's slice points
  into `front`, which stays frozen until the backend reports the write complete,
  while everything queued meanwhile appends to `back` — appending to the
  borrowed buffer could realloc its storage out from under the kernel, which is
  a lifetime bug, not a saving. When the write drains, the emptied front (burst
  capacity freed, steady capacity retained) swaps with the back and the queued
  bytes submit. The steady retention is per-buffer: front and back each keep up
  to 16 KiB, so the true steady ceiling is 32 KiB per connection, not 16.
  Boundedness is read backpressure: pending bytes past the
  high-water mark (`Options.outbound_high_water`, default `frame_cap`), counted
  across both buffers, park that connection's reads, so no new inbound frames
  can mint new replies. Deleting the copy would mean writing borrowed frame
  bytes asynchronously, which is the same lifetime bug. Deleting the bound
  reopens the slow-reader memory hole. The iroh completion `Backend` shares
  this posture over its single `outbound` buffer (ADR-0057): a `try_write` that
  returns `WOULD_BLOCK` leaves the tail queued, and while pending outbound
  exceeds `Options.outbound_high_water` (default `frame_cap`) the loop stops
  draining that connection's inbound from the sidecar, so the sidecar's inbound
  buffer fills and QUIC flow control throttles the partner; the read resumes
  when a writable fully drains the queue, which also frees burst capacity
  above `steady_outbound_bytes`. It is one buffer, not two, because
  the iroh path copies into the sidecar rather than lending the kernel a slice.
- **Pinned tcp stream wrapper: `net.tcp` per connection (ADR-0043).** A
  transport-generic `Connection` borrows `*std.Io.Reader` / `*std.Io.Writer` and
  is moved by value, but `std.Io.Reader`'s vtable recovers its concrete
  `Stream.Reader` from `&interface` by field offset. The concrete reader and
  writer therefore need a stable address outside the movable connection. tcp
  pins one `TcpStream` (its reader, writer, io) per connection on the peer's
  allocator at connect/accept and frees it through the connection's
  `TransportHandle.close`. One small allocation on the blocking `BlockingSession`
  path only; the completion loop never builds a `Connection`, so peer-scaling
  memory is untouched. Deleting it means storing the stream inline, which
  dangles the borrowed interface pointers the moment the connection is moved.
  The iroh resident pins the identical wrapper for the identical reason
  (`IrohStream` in `src/net/transport/iroh.zig`, ADR-0055), freed the same way
  through its connection's `TransportHandle.close`.
- **Loop-bridge connection shells and the slot map: `driver.Bridge`
  (ADR-0076).** The bridge that feeds the byte-fed `driver_core.Host` from
  `completion.Loop` (`net.TcpLoop` / iroh Backend) retains two classes, both
  bounded by live connections. Each
  adopted connection gets one heap `Bridge.Slot` shell (the loop's
  per-connection hook context: the `Conn`, the slot, the open
  edge), created in `makeConnCtx` and destroyed in `freeConnCtx`. The
  ConnId→slot map row that routes `flush`/`close` actions to
  `Loop.armOutbound`/`closeSlot` is inserted at adoption and removed first
  thing in `freeConnCtx` — before the release's drain runs — so a teardown
  drain can arm sibling slots but never the dead one. The peers themselves
  are never bridge-owned: the loop's fixed slots hold them inline and the
  host adopts without freeing (`Host.openAcceptedOver` over
  `engine.Node.registerConnOver`).
- **Owned inbound frame: `ownedFrameFromView` (`Peer.recvBorrowed`).** A
  borrowed `FrameView` is transient; a surfaced event must outlive it, so the
  bytes are copied once into an owned `Frame`. Word-shaped frames need
  8-byte-aligned storage, hence `alignedAlloc` + `@memcpy` rather than `dupe`.
  The owned-frame and zero-copy borrow paths split exactly here. This is the
  _only_ allocation a steady-state inbound deliver to a live export costs. This
  is the irreducible wire-path floor asserted by
  `test/engine/alloc_budget_test.zig`.
- **Borrowed validation, owned only when retained: `Session.recordRecvView`.**
  The session is codec-neutral but `model.view.Body` is a codec-neutral
  _borrowed_ projection over the frame, so the common inbound kinds (deliver /
  resolve / listen / start-session / abort) validate and apply session authority
  directly from it, with zero per-turn materialization. The engine-synthesized
  V1.0 resolver-callback resolve (ADR-0010) joins them through
  `Session.recordResolverCallbackResolve`, which applies the borrowed resolution
  view with the same zero-copy shape, minus the wire-`op:resolve` refusal that
  path never earned. An owned `Message` is materialized only on the two paths
  that _retain_: a pipelined deliver queued on its answer
  (`Peer.maybeEnqueuePipelinedCall`), and the rare sub-structure-heavy kinds
  (`gc_*`, `handoff`, `get`/`index`/`untag`) that fall back to one owned
  validate/apply.   That owned-fallback copy is _turn-scratch_, not session-lived:
  it feeds the shared owned validate/apply and dies when the turn ends, so it is
  materialized into the session's **`recv_scratch`** bump arena and reclaimed
  with one `reset(.retain_capacity)` at the end of every `recordRecvView`,
  `recordRecv`, and `recordResolverCallbackResolve`. The
  inbound GC validators' duplicate-position fold
  (`checkGcExportDecrement` / `checkGcAnswerDecrement` in `validateRecv`) —
  a fixed stack for typical small vectors, spilling to a map only above the
  threshold — bumps the same arena on spill and dies in the same reset; only
  the send-side GC validation keeps its gpa scratch with a precise deinit,
  because no recv turn brackets it. The inbound set-uniqueness fold
  (`checkInboundSetUniqueness` in the same walk) rides the same arena: an
  inbound set's elements are materialized once on the borrowed path and hashed
  (`model.equality.argumentHash`) to group candidates, an Equal pair is
  refused `DuplicateSetElement`, and the rows die in the same reset. It is the
  codec-neutral backstop for the byte-level ascending-element refusal the
  Syrup decoder gets for free; Cap'n Proto's pointer wire form cannot prove
  set uniqueness without it, and a set-free frame pays nothing.
  The per-message dupe-then-`freeMessage` choreography collapses to a
  bump-and-reset, and capacity amortizes across turns. Apply dupes anything
  session-lived onto the gpa, so resetting the scratch can never dangle a table
  row. One inbound deliver/resolve's argument bytes are walked exactly once
  between validate and apply: the validate walk records every introduced far
  mention into an arena-backed `validate.IntroducedImports` (allocation-free
  for the common no-reference message) and apply consumes that record instead
  of re-walking the borrowed view; validation still completes fully before any
  mutation, so apply's `registerImport` can only fail on OOM. The walk is
  depth-bounded (`SessionLimits.max_nesting_depth`) so an attacker-nested arg
  tree fails loud with `NestingTooDeep`, which projects to a
  `resource_exhausted` abort, instead of overflowing the native stack.
- **Settled-outcome materialization: one `model.cloneArgument` (or one
  broken-reason dupe) per blocking driver wait — `driver.BlockingSession.call` /
  `fetchSettled` and `driver.Session.call` / `settleVow` — into
  the caller-supplied allocator (`SettleCapture`).** The settling listener
  fires with a turn-borrowed resolution that dies when the turn ends, while
  the returned `driver.Settled` must outlive the blocking drive; this one
  boundary copy into the caller's arena is what severs that borrow.
  `BlockingSession.fetch` and `Session.fetch` / `enliven`
  stay the allocation-free path: they record only the POD far ref and never
  retain the break reason.
- **Unobserved host-vow completion: one deep clone per settle with no
  in-process listener (`driver_core` host `queueCompletion`), moved — never
  re-cloned — into whoever drains it.** The settle fires inside `feed` while
  the resolution is turn-borrowed, and an embedder that only drains the
  action queue reads it after `feed` returns, so the owning completion is the
  one durable holder (a wait registered through the core's `vowOn` hears the
  settle borrowed and pays nothing here; a failed clone degrades to an empty
  break rather than a lost vow). It is the *only* copy on the path: the
  action queue's two pops split by ownership — the C ABI's
  `pancake_host_next_action` borrows through `nextAction` (views valid until
  the next pop, which frees them), and a Bridge/`takeAction` embedder pops
  owned and can park the outcome with zero further clones. The old drain-side
  re-clone
  was re-derived against the full option set and deleted: the popped action
  is a transient carrier, and the parked table is the durable owner that can
  simply adopt it. Freed once — at the next borrowed pop, by the adopter
  (`Parked.deinit` when the wait collects it, materializing once into that
  wait's caller arena), or with the undrained queue at teardown. Bounded by
  the application's own unsettled sends.
- **Crypto fixed-width materialization: `crypto.PeerKey.fromSlice`,
  `crypto.Signature.fromParts`.** `std.crypto` Ed25519 operates on fixed-size
  arrays (`[32]u8` / `[64]u8`) while the wire exposes `[]const u8`.
  Materializing the array from a borrowed slice is an inherent, bounded copy at
  the verification boundary. `std.crypto` offers no allocator pattern to avoid
  it.
- **Authoritative session state: the owned locator clone (`owned.zig`'s
  module-private `clonePeerLocator`), plus the per-session
  byte key arena.** Session tables are the source of truth and outlive any
  borrowed frame, so an owned `op:start-session` locator is duped into
  session-owned storage. The byte-keyed tables are position/key-keyed hash maps
  (no linear `std.mem.eql` scans): exports / imports / answers are O(1)
  position-keyed `SlotTable` / `AnswerTable`; the _Session's_ `bootstrap`
  registry is an O(1) `StringHashMap` whose swissnum key bytes live in one
  per-session **`key_arena`** (alongside the partner key/designator bytes),
  freed wholesale at teardown. The _monotonic_ tables never remove a row, so a
  bump arena is the right owner. Deliberately excluded from the arena: the
  FIFO-evicting `sturdyref_cache` (plus its side swissnum→index map) and the
  individually-removed `pending_enlivens` / imported-promise hosts keep their
  swissnum / host bytes on the gpa with precise per-row frees, because a bump
  arena cannot reclaim an evicted or removed row and would leak under churn.
- **Vat-scoped gift registry: gpa rows with per-row frees
  (`engine.bootstrap.GiftRegistry`, ADR-0056).** The single gift / handoff-count
  authority. Every `Peer` owns a private registry (`own_gift_registry`, freed in
  `Peer.deinit`); a host serving several direct sessions to one vat points its
  peers at one shared registry instead, keeps it alive past every peer's
  `deinit`, and owns any cross-thread locking; the registry carries no lock.
  Its tables are _not_ monotonic: a re-deposit of the same gift id replaces the
  prior row by freeing its recipient key, gifter key, and gifted reference, so
  the rows live on the gpa with precise per-row frees, never in a bump arena (an
  arena cannot reclaim an overwritten row and would leak every re-deposit). Each
  deposit dupes the gift id, recipient key, and gifter key and adopts the gifted
  reference; each first-seen recipient session dupes its session id (bounded by
  `max_seen_handoff_counts`); every row is freed precisely, on overwrite or
  registry deinit. A consumed gift's whole row is removed at withdraw (id key,
  all three keys, and the gifted reference freed), so a process-lifetime registry
  pins neither a capability nor a row per handoff it ever served; replay stays
  blocked by the monotonic `handoff_counts`, not a retained marker. Because a
  consumed row is gone, the row count _is_ the live-gift count, so
  `max_deposited_gifts` bounds `gifts.count()` directly — no parallel counter to
  drift — and a node that has served many completed handoffs keeps accepting new
  deposits.
- **Withdraw verbatim-cap clone: one `model.cloneReference` per `withdraw-gift`
  that hands back a non-`near` gifted capability
  (`engine.bootstrap.resolveForWithdraw`).** `applyWithdraw` reclaims the gift
  row's payload before the settled resolve can be encoded, so a verbatim gifted
  cap (`sturdy` / `broken` / `promise`) is cloned clear of the row first and the
  clone rides in the settled message. `Peer.sendWithdrawSettled` copies it onto
  the wire with `sendCopying` and then frees it through
  `bootstrap.freeSettledWithdrawOwned`, so the withdraw responder is the single
  owner and neither inbound call site guesses. A re-exported `near` gifted cap
  and the static-break refusal arms are POD, so that free is a no-op for them —
  only a verbatim cap allocates. Deleting the clone would dangle the settled
  message on the row `applyWithdraw` just freed.
- **Parked withdraw: one owned handoff-receive per early `withdraw-gift`
  (`Peer.pending_withdraws`, ADR-0056).** A `withdraw-gift` whose gift has no
  live deposit must outlive the borrowed frame that carried it, so the receive
  is materialized once onto the peer's gpa and parked. `Peer.step` retries
  parked entries against the gift registry and frees each when its withdraw
  settles; the rest are freed at `Peer.deinit`. Bounded by
  `max_pending_withdraws` (loud `PendingWithdrawCapExceeded` on overflow).
  Refusing the early withdraw instead would break the protocol's
  deposit-may-arrive-second contract, which the upstream OCapN suite pins.
- **Listener fan-out: POD fire carriers over the stored resolution; zero
  payload copies.** When a promise with N listeners resolves, each fire is
  queued as one POD carrier (`engine.Outbound.listener_fire`, whose `target`
  names the store holding the resolution — an inbound answer or a relayed
  third-party import) and `Peer.step` borrows that resolution back at encode
  through the one keyed lookup (`Peer.resolveFireStore`, over `peekResolution`
  or the imported-promise row) to build the wire deliver on the stack
  (`engine.pipeline.borrowedListenerFire`). Queue-time session accounting runs
  on that same borrowed stack message in the sent-resolve order
  (reserve-then-record-then-push), so the wire-delta retains commit before the
  infallible enqueue — and those early retains are load-bearing, not just
  bookkeeping: they pin the payload's `near` exports across the queue→encode
  window against a legal partner `op:gc-exports`, which is why fire accounting
  cannot move to encode time. Every carrier is stamped with its store row's
  identity (`Session.store_stamp_counter`, one session-wide source so no two
  row instances share a stamp): a row gone at encode, or one whose identity
  changed (the position was released and reused — partner-named
  answer positions, or a torn-down-and-re-registered third-party import),
  leaves the fire moot — nothing emits, the same semantics `settled_answer`
  ships — and its queue-time export retains stay recorded until session end
  (the identical stranded-retain posture the settled-answer path already
  carries, observable as the export refcount exceeding emitted mentions). A
  surviving row's stored payload cannot change under a queued carrier —
  an answer resolves once and a relayed resolution records once
  (`recordRelayedResolution` refuses a second relay) — so a matching identity
  stamp proves the payload the carrier was accounted against is the one that
  ships. Pinned by
  `test/engine/listener_fire_budget_test.zig` (budget, gc drop, stranded
  retain, answer reuse) and the second-relay-refusal / re-registration
  scenarios in `test/engine/peer_test.zig`: three listeners fire with zero
  resolution-payload copies. The drain spine
  _moves_ POD: drained entries flow through
  `engine.pipeline.ListenerDrainAction` (every variant a plain value — a
  listener entry is a POD `FarRef`, so the old per-partial-fire
  `cloneReference` re-anchor collapsed into a value copy and is gone) onto
  `pending_send` / the listener table without touching heap.
- **Sent-resolve store: the resolution _moves_ into the answer row; the wire
  path copies nothing (`Session.applySentResolve`).** A sent `op:resolve`
  transfers ownership of its resolution into the inbound answer's store (a
  consume contract: `recordSend` frees it on any refusal, so the caller never
  frees it), and the queued outbound carrier (`engine.Outbound.settled_answer`)
  holds only the answer position, `Peer.step` reads the resolution back from
  the store via `peekResolution` to encode. The store is the single owner: a
  late pipelined call redirecting off the settled answer and a late `op:listen`
  firing with the value both read it in place; it is freed once on overwrite or
  answer teardown (`deinitAnswerCell`), bounded by `max_inbound_answers`. A
  move is safe where a borrow would dangle precisely because the encoder reads
  through the store at emit: an inbound `op:gc-answers` dropping the row between
  record and emit leaves nothing to encode rather than a stale pointer. The only
  per-resolve wire-path allocation is the answer's lazily-created payload row,
  pinned with **zero** resolution copies by
  `test/engine/resolve_alloc_budget_test.zig`. (The V1.0/pipelined projection
  path clones its borrowed projected resolution once, that is `sendCopying`'s
  boundary copy, above, then moved into the store here, not a second copy.)
- **Projection anchors: one dupe of the field name / tag per inbound `op:get` /
  `op:untag` (`Peer.respondToProjection`).** A projection waits on its source
  answer, so it outlives the borrowed view that carried the field or tag; the
  bytes are duped into a `session.Projection` the answer row owns. (`op:index`
  carries an integer and dupes nothing.) Freed exactly once through
  `deinitProjection` — on fire, break, re-anchor failure, or answer teardown —
  and bounded per answer by `max_listeners_per_target` (ADR-0050).
- **Boxed handoff argument: `owned.zig`'s module-private `cloneHandoffBoxed` (one alloc per
  `desc:handoff-*` _argument_).** The owned `Argument.handoff` arm is
  `*Handoff`, not inline: a handoff payload is ~160 bytes and would otherwise
  set the size of _every_ `Argument`, so an ordinary integer arg in a deliver
  list would pay for the handoff arm it never uses (`Argument` 168 → 88 bytes,
  `Resolution` 176 → 96; measured by `bench/frame_view_bench.zig`). The cost is
  one `create(Handoff)` only when a handoff actually appears as an argument,
  which is rare and limited to three-party work. It is freed once in
  `freeArgument`. The borrowed `model.view.Argument` keeps its handoff inline;
  it borrows wire bytes and never allocates, so the box lives only on the
  owned/retain side.
- **Local-delivery frame synthesis: `Peer.deliverDrainedCallLocally`.** When a
  pipelined call's answer resolves to a _local_ export, the drained call is
  delivered to that export by encoding the re-targeted `op:deliver` into a fresh
  `Frame` and surfacing it as an event. It has the same shape as a directly
  received deliver, so the application dispatches it uniformly. The queued
  message itself _moves_ into the rewrite; the one allocation is the synthesized
  frame, which the frame-based event model requires (a borrowed frame can't
  carry a message that never arrived on the wire). Bounded by
  `max_local_deliveries`.
- **Relayed-resolution forwarding: lower, store once, then fire from the store
  (ADR-0009, ADR-0069).** `Peer.applyRelayedResolution` lowers any node-local
  foreign-import token in the application-supplied resolution in place
  (`engine.lower.lowerResolution` — this path bypasses `send`'s lowering
  chokepoint, so it lowers here before anything durable owns the value), then
  _moves_ it into the import's stored slot via
  `Session.recordRelayedResolution`, and only
  then queues the listeners' fire carriers, which borrow the stored value at
  encode like every fire in the fan-out above. The store is written exactly
  once per row: a promise resolves once, so a second relay for a settled
  import is refused (`Error.UnexpectedMessage`, the answer-side
  `validateInboundResolve` rule mirrored) with the refused resolution freed.
  There is no clone of the resolution anywhere on the relayed path. A late
  `op:listen` fires the same way, from the store; the stored resolution is
  freed once (on import GC co-eviction or session teardown).
- **Sturdyref enliven dedup: one swissnum dupe per cache or in-flight row
  (ADR-0012).** `Session.cacheSturdyrefEnlivenment` and `notePendingEnliven`
  each `dupe` the swiss-number into a session-owned row; the resolved cache
  stores only the `(import_position, kind)` POD alongside it, never a clone of
  the enlivened reference. A side `StringHashMap` (swissnum → FIFO index) keeps
  lookup O(1) and stays in lockstep on insert and eviction. `engine.sturdyref.recordEnlivenment`
  _moves_ the fulfilled `Reference.far` out to the caller (POD `FarRef`, no heap)
  and copies just its `import_position` + `kind` into the cache. The cache is
  non-load-bearing: an overflow evicts the oldest row and frees its swissnum. A
  failed insert is swallowed because a miss costs one extra bootstrap-fetch
  round-trip, not correctness. Each owned swissnum is freed once on
  overwrite-evict, `finishPendingEnliven`, or `Session.deinit`.
- **Byte-fed host completions: one deep clone per unlistened vow settle
  (`driver_core.Host.queueCompletion`).** A vow with no in-process listener
  settles as an owned `settled`/`failed` action on the embedder queue: the
  settle fires inside `feed` while the resolution is turn-borrowed (the vat
  arenas reset before the embedder can drain), and the drain happens after
  `feed` returns, so an owning completion is the only correct holder. Bounded
  one per vow, freed at the next `nextAction` (the DIAL locator's exact
  lifetime contract) or at host teardown; the one-loop rule drains after every
  top-level call, so steady state is one feed's settles. In-process listeners
  (`vowOn`) stay borrowed zero-copy, so the clone is paid only at the byte
  boundary. Fire cannot strand: every vow mint and fallible enqueue reserves
  one queue slot per live vow, so the fire's append is infallible, and a clone
  failure degrades to a `failed` completion with an empty message
  (zero-allocation) rather than a stranded vow.
- **Canonical set ordering: one standalone encode per set element on outbound
  encode, in both codecs.** A set is unordered, so its wire form must not depend
  on the order the model held it in; canonical order is defined over _encoded
  bytes_, which means each element is encoded once just to obtain its sort key
  (`syrup.writeCanonicalSet`, `capnp.canonicalSetOrder` / `encodeArgumentKey`),
  plus the per-set sort scratch. Syrup struct encode pays the same per-entry
  encode-then-sort (`writeCanonicalStruct`), and a hinted locator's hint dict —
  once per keyed start-session, never per turn — pays it too (`writeHintDict`);
  capnp struct ordering is cheaper,
  a shallow entry copy sorted by raw key bytes. All of it is turn-scratch
  bounded by the caller's own message and freed before encode returns. Deleting
  the key encode means sorting on model values, which two encoders can disagree
  on; the bytes are the only order both sides reproduce.

### Named Deferred Costs

- _(empty.)_

## Per-session footprint budget

The 500k-connection destination is a budget gated by the build (ADR-0045), so a
field added to session state is a withdrawal from it, not free. `engine.Peer`
carries a `comptime` ceiling on `@sizeOf(Peer)` (one kilobyte), and
`test/engine/footprint_budget_test.zig` holds a warmed session's core state at
or under 2 KiB per session. If your change trips either gate, the fix is to
weigh the bytes and raise the budget deliberately — in the constant and in
`docs/ladder.md` rung 2 together (the ladder owns the numbers) — never to route
around the check.

The engine's four peer queues each bound their retained backing at
`steady_queue_bytes = 4096` (`src/ocapn/engine/mod.zig`): capacity a burst grew
above the bound is freed at the drain point, at the named price of one growth
re-allocation when the next burst begins. The actor layer holds the same
posture at one-vat-per-connection scale (`src/actors/vat.zig`, constants next
to the vat's fields): `steady_turn_arena_bytes`, `steady_queue_arena_bytes`,
and `steady_settle_arena_bytes` (each 4096) bound the three vat arenas via
`reset(.retain_with_limit)` at their existing reset boundaries, and
`steady_list_bytes` (4096) bounds the `queue` / `moved_replies` ArrayLists via
`clearAndFree` above the bound at their drain points.
`test/actors/vat_footprint_budget_test.zig` holds a burst-then-quiescent vat
back under these bounds.

The completion loop wraps each `Peer` in one `Conn` slot — the unit it allocates
`max_conns` of — so that wrapper carries a ceiling of its own: a `comptime`
assertion in `src/net/completion/loop.zig` holds `@sizeOf(Conn) -
@sizeOf(engine.Peer)` at or under `conn_slot_overhead_bytes` (120), isolating the
wrapper's bookkeeping from the `Peer` the one-kilobyte ceiling already guards.
The number moves in the constant and in `docs/ladder.md` rung 2 together, like
every other footprint gate.

## Allocator Discipline

- The owner that allocates releases.
- Store enough metadata to free correctly; word storage must be freed with word
  alignment.
- Never hide allocation behind a neutral API name.
- Do not add `unsafe` as an optimization shortcut. Escalate first.
- A map removal whose key presence is an established invariant asserts the
  removal (`std.debug.assert(map.remove(k))`, which still runs the remove in
  release and only adds the check in safe builds); only a genuinely idempotent
  ensure-absent removal discards the bool, and then it carries an inline
  `// idempotent:` or `// tolerant:` justification. `zig build meta-check` holds
  this for every `_ = <map>.remove(` / `.fetchRemove(` / `.swapRemove(` in `src/`.

If a caller cannot tell whether an API transfers, borrows, or copies, the API is
wrong.
