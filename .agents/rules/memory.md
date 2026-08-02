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
  `step` drain/encode failure — by committing a fresh outbound `op:abort`
  through `Peer.commitAbortOutbound`, bypassing `recordSend`. Aborts are
  always admitted because the session is being refused or torn down. The
  abort's diagnostic is a static `[]const u8` borrowed by encode, so there is
  no message clone. This path is best-effort: an encode or append failure is
  swallowed so the original dispatch error is never masked; when the
  projection requires close, the session still closes even without a queued
  frame.
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
  into one ingress queue chunk.** Actor-local, not wire-path: this is the far
  path's `Peer.sendCopying` contract replayed inside one vat. A queued local
  turn runs at a later `drive`, whose first outermost turn resets the turn
  arena — the very arena the documented handler pattern builds outgoing args in
  — so an owning queue plus borrowed input again requires exactly one copy.
  Before cloning, `model.measureArgumentSliceOwnedBytes` walks the same complete
  ownership shape and adds the verb and queue row; admission can therefore
  refuse a per-ingress turn, byte, or chunk limit before any queue mutation.
  The clone (verb plus deep args, via `model.cloneArgumentSlice`) lands in the
  selected chunk's bump arena. A completed chunk is reclaimed independently of
  other ingresses; one Vat-wide spare retains at most
  `steady_spare_arena_bytes`, and an empty ingress retains no chunk. The settle
  side pays the mirror-image copy, and it is arena-homed on both paths. Each
  settle clone defends two hazards: a listener may open a top-level turn
  (`near` or `drive`) whose depth-0 turn-arena reset would free a turn-arena
  value mid-call, and the value may borrow the settling actor's own mutable
  state, which a listener-run turn can mutate or `become`-free under the
  borrow — so the clone can be re-homed, never deleted. Local and far fulfilled
  listeners clone into the same depth-guarded `settle_arena`, reset when
  `settle_depth` returns to zero. That guard covers both a local listener opening
  a nested drive and a far listener re-entering `serve` through a driver pump
  (`BlockingSession.step` → `drainEvents`). The far
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
  and installs it at turn end (a handler error frees the staged box instead).
  The install swaps the cell's box immediately but does *not* drop the old
  live ref there: the outgoing box moves to `Vat.retired_boxes` and its
  reference falls at the next outermost turn, the same boundary that reclaims
  `moved_replies`. That is the reply's documented lifetime, and it is what a
  same-frame sever cannot cover. An _earlier_ frame of the same actor may
  have already handed a caller a reply borrowing that box and returned, so
  there is no live frame left to copy it. `stageBecome` reserves the retire
  slots, one per open frame rather than one per stage: every frame open at
  that moment can hold a staged become and none has installed yet, so they all
  see the same list length, and the unwind then appends once per frame. What
  the retire list holds is therefore one outermost turn's become installs, not
  a quantity the actor graph bounds — a handler that loops over a becoming
  actor retains one state box per iteration until its turn ends, the same
  shape the turn arena already has for that handler's own allocations.
  Capacity above `steady_list_bytes` is returned at the drain, so the steady
  footprint stays bounded; `test/actors/vat_footprint_budget_test.zig` holds
  it. The clone and copy-on-write paths are bounded by the application's own
  actor graph, and every box is freed through the single `releaseBox`
  chokepoint when the last reference — live cell or snapshot — drops. Deleting the box layer forces an
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
- **Bounded inbound spill: `foundation.Spill` (ADR-0041).** Where stream bytes
  wait when they have arrived but do not yet make a whole frame. It lives in
  `foundation` because both tiers that read a stream need one and neither can
  import the other: `net` folds a parser over a live byte stream, and
  `driver_core` is byte-fed and imports no transport. It is bytes and nothing
  else, which is what lets them share it, and the reader-shaped fill
  (`net.absorbFrom`) stays up in `net` because the core holds no transport
  type. Each tier names what a drained spill keeps, and that number is the only
  thing they differ on.
  At the `net` tier (`net.Spill`, retaining `net.spill_retain_bytes` of
  nothing) read buffers size the steady state, so an admissible frame larger
  than the read buffer pays one extra bounded copy (read buffer into spill) and
  one allocation per oversize burst, freed when the spill drains. The fast path
  (frame fits the buffer) stays a zero-copy borrow with no allocation.
  Boundedness is the codec's cap-during-scan verdict plus a defensive
  incomplete-at-cap mirror in `codec.dispatch.framePrefix`. Deleting this
  relocates the cost into `max_frame_bytes`-sized per-connection read buffers,
  which is the exact scaling problem ADR-0041 removed.
- **Byte-fed session stream tail: `HostSession.feed_tail`
  (`driver_core.Host.feedBytes`).** The same `foundation.Spill`, at the
  byte-fed host tier, as the one owner of the unconsumed stream tail — the
  buffer four binding pumps each used to keep by hand. The steady path (no
  pending tail) parses the borrowed chunk in place with zero copies and
  stashes only a partial frame's leftover; while a tail is pending, each
  chunk pays one bounded coalesce copy into it, the delimiter's
  contiguous-bytes price the bindings paid before, now paid once. Bounded by
  the cap-during-scan verdict plus the embedder's own read size (a big read's
  frames coalesced behind the handshake hello wait here too). Straddling a
  chunk boundary is ordinary traffic here rather than the exception it is over
  a read buffer, so this tier keeps `steady_feed_tail_bytes` of capacity on a
  full drain instead of freeing outright, and the shell frees the rest.
  Deleting it hands the tail back to every binding, which is the exact
  hand-copied choreography this owner removed.
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
- **WebRTC callback bridge: one bounded inbound deque and one bounded outbound
  batch per peer (ADR-0089).** `webrtc` 0.14 delivers DataChannel messages through
  a serialized callback rather than a borrowed stream read. The callback copies
  each message once into the peer's inbound `VecDeque`; `try_read` copies its
  contiguous prefix once into caller storage. The pinned crate's read loop awaits
  one callback before reading the next, so checking the 1 MiB bound before that
  callback parks limits overshoot to one at-most-64-KiB message and lets SCTP flow
  control throttle the partner. A full drain shrinks retained capacity to 16 KiB.
  The outbound side pays one copy into `BytesMut` (plus its bounded amortized grow
  moves), counts queued and in-flight bytes together under 1 MiB, and splits the
  moved batch into 16 KiB `Bytes` views without another copy. The batch allocation
  dies when sent, so a burst does not pin its high-water capacity; a write larger
  than available room admits a prefix so retry can progress. This is **name**:
  deleting either boundary copy would require the callback or async send task to
  retain caller storage past the call. The two-worker Tokio runtime and readiness
  queue are endpoint-owned, not per peer; readiness retains at most one pending
  row per ready peer and coalesces its event bits. Its self-pipe writes are
  best-effort only under one invariant: `WouldBlock` means unread bytes already
  fill the pipe, so the read fd is already poll-readable and no wake was lost.
  The same `Readiness.nudge` technique is used when an event is published and
  when a bounded record drain leaves backlog; interrupted writes retry. The
  exported fd is the socketpair half whose write direction is shut down, so a
  consumer cannot manufacture a wake byte.
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
  `engine.Node.registerPeerOver`).
- **Owning host face wires: one `Wire` shell plus two `frame_cap` buffers per
  session, and per-host poll scratch (`driver.PollHost`, ADR-0090).** The blocking
  application tier, not the 500k loop tier. Each session's transport binding
  is one heap `Wire` (the `net.Connection`, the read/write buffers its
  reader/writer own, the core shell pointer), freed only by its owner — the
  view's `deinit` or host teardown; an EOF marks the wire closed and breaks
  that session's vows without freeing, because a view still holds the
  pointers (the close/release split). The pump's readiness wait fills three
  host-owned scratch lists (pollfds, wire pointers, and the borrowed
  connection pointers `net.waitAnyReadable` takes) sized to the live wires,
  so the wait allocates nothing once they have grown; a `connect`
  bundle adds one core `Host` (node, identity, tables) per session, the
  named price of the front door redeeming handoffs. Frames written to a wire
  are freed after the write; the read path parses borrowed reader bytes
  through `Host.feedBytes` with no copy beyond the core's own feed-tail
  contract.
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
  with one `reset(.{ .retain_with_limit = steady_recv_scratch_bytes })` at the
  end of every recv entry point: `recordRecv`, `recordRecvView`,
  `recordInboundDeliverView`, and `recordResolverCallbackResolve`. Retaining
  the whole capacity instead would pin one burst's peak for the session's
  life, which is the hazard the footprint budget below exists to stop. The
  inbound GC validators' duplicate-position fold
  (`checkGcExportDecrement` / `checkGcAnswerDecrement` in `validateRecv`) —
  a fixed stack for typical small vectors, spilling to a map only above the
  threshold — bumps the same arena on spill and dies in the same reset; only
  the send-side validation scratch (the GC dedup, and the set / struct-key
  uniqueness folds in `validateArgument`) stays on the gpa, stack-first with
  spills freed precisely, because no recv turn brackets a send. The inbound
  set-uniqueness fold
  (`checkInboundSetUniqueness` in the same walk) rides the same arena: borrowed
  set elements are hashed/compared as views (`viewArgumentHash` /
  `viewArgumentsEqualBounded`) with scratch holding only view handles and
  hash rows — no `toOwned` materialization. An Equal pair is refused
  `DuplicateSetElement`, and the rows die in the same reset. Confirming is
  bounded work, not free work: two sets compare as multisets, so an
  equal-hashed pair of width N costs on the order of N² element visits, and
  the commutative set hash lets a partner construct that pair deliberately.
  Every visit charges a per-message allowance
  (`SessionLimits.max_compare_visits`) carried on the turn's
  `IntroducedImports` record — turn state, so it costs the per-session
  footprint nothing — and exhaustion refuses `CompareBudgetExhausted`
  (projecting to `resource_exhausted`) instead of grinding. It is the
  codec-neutral backstop for the byte-level ascending-element refusal the
  Syrup decoder gets for free; Cap'n Proto's pointer wire form cannot prove
  set uniqueness without it, and a set-free frame pays nothing. The owned fallback arm and the send-side
  fold run the same comparison spine through `argumentsEqualBounded` (the
  owned entry points project through `view.*.fromOwned`, so there is one
  spine, one hasher, and one budget discipline). On a Syrup
  frame the fold therefore re-verifies what decode already refused: one named
  redundant walk per inbound set, kept so the invariant is codec-neutral
  instead of a per-codec trust.
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
- **Introduced-import event patch: one gpa dupe per reference-introducing
  deliver (`engine/inbound.zig`, surfacing `Event.introduced_far_imports`).**
  The validate walk's `IntroducedImports` record above is turn-scratch, gone
  before the embedder sees the event, while the surfaced event outlives the
  turn — so the mention list is duped once onto the gpa and freed by
  `Event.deinit`. The common no-reference deliver pays nothing. The dupe is
  best-effort by contract: apply has already committed when the patch runs, so
  an OOM leaves the field null and `gc` falls back to its own walk rather than
  misreporting a successful receive as a failure.
- **Owning-facade lower/lift boundary (`driver.Session`, ADR-0096).** Every
  owning-tier verb lowers its `Value` args through a per-verb scratch arena
  (spine containers only; leaf bytes stay borrowed) before the actor layer's
  own ingress clone, and every `Reply`-returning wait lifts the captured
  settlement into the caller's arena: spines allocated there, leaves aliasing
  the capture, capability rows retained through `liftCapabilityTracked` under
  rollback receipts. This is the application tier, not the wire path — the
  engine's budgets are untouched, and the settle capture below remains the one
  payload copy; the lift aliases it rather than re-cloning, which is why
  `Reply` is arena-only and carries no `deinit`. The `Hosting` bridge pays the
  same two walks per delivered turn, in the turn arena.
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
  the resolution is turn-borrowed (the vat arenas reset before the embedder can
  drain), and an embedder that only drains the
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
  wait's caller arena), or with the undrained queue at teardown. The one-loop
  rule drains after every top-level call, so steady state is one feed's settles,
  and the fire cannot strand: every vow mint and fallible enqueue reserves one
  queue slot per live vow and per parked enliven, so the fire's infallible
  append never fails. Bounded
  by the application's own unsettled sends. Session mint also reserves one
  flush and one close notification slot per live shell. Those irreversible
  notifications use intrusive pending bits and infallible pushes, never a
  linear dedup scan or an allocation after a frame/close verdict exists. Before
  destructively popping a Node action, the Host reserves its largest possible
  action-queue consequence; action drain can therefore report OOM without
  losing the Node action. The action FIFO retains its historical reservation
  peak until Host teardown because a drain must not revoke capacity promised to
  a future vow fire or session notification.
- **Off-turn settle mailbox: fixed slots at init, one boundary clone per post
  (`driver.SettleMailbox`, ADR-0102).** The slot array (each slot one fixed
  `slot_payload_bytes` store) is allocated once at init, so a worker thread's
  `post` allocates nothing: the plain-data resolution clones into the slot's
  fixed-buffer arena under the spin lock, refusing `ValueTooLarge` past the
  store and `MailboxFull` past the ring — backpressure, never growth. That
  clone is the cross-thread boundary copy: the worker's value dies with its
  frame while the owning thread applies later. The wake socketpair carries
  nudge bytes only. Deleting the clone means the owning thread reading
  worker-owned storage after the worker moved on, which is a lifetime bug,
  not a saving.
- **Crypto fixed-width materialization: `crypto.PeerKey.fromSlice`,
  `crypto.Signature.fromParts`.** `std.crypto` Ed25519 operates on fixed-size
  arrays (`[32]u8` / `[64]u8`) while the wire exposes `[]const u8`.
  Materializing the array from a borrowed slice is an inherent, bounded copy at
  the verification boundary. `std.crypto` offers no allocator pattern to avoid
  it.
- **Borrowed handoff canonicalization: one owned signing-domain buffer per
  certificate; Cap'n Proto lazy hints add call-scoped projection scratch.** An
  immediate withdrawal never owns the inbound handoff tree. Give and receive
  verification each allocate only the canonical byte product the crypto API
  consumes. A Syrup-forwarded give carries its exact signed envelope, so receive
  canonicalization bypasses typed hints and the split signature is joined on the
  stack. Cap'n Proto carries typed lazy hints instead; projecting a non-empty
  hint list for the Syrup canonical encoder temporarily owns its bounded
  entries/bytes and frees them before return. If the withdrawal parks, the
  separate pending-row materialization is the lifetime-boundary copy.
- **Authoritative session state: the owned locator clone (`owned.zig`'s
  module-private `clonePeerLocator`), plus the per-session
  byte key arena.** Session tables are the source of truth and outlive any
  borrowed frame, so an owned `op:start-session` locator is duped into
  session-owned storage. The byte-keyed tables are position/key-keyed hash maps
  (no linear `std.mem.eql` scans on any per-turn path): exports / imports /
  answers are O(1)
  position-keyed `SlotTable` / `AnswerTable`; the _Session's_ `bootstrap`
  registry is an O(1) `StringHashMap` whose swissnum key bytes live in one
  per-session **`key_arena`** (alongside the partner key/designator bytes),
  freed wholesale at teardown. Host-wide publication is a separate O(1)
  `StringHashMap`; exact gifts retain the deposited Vat target and perform no
  swiss reverse lookup at withdrawal. The _monotonic_ session tables never
  remove a row, so a bump arena is the right owner. Deliberately excluded from
  the arena: the FIFO-evicting `sturdyref_cache`
  (plus its side swissnum→index map) and individually-removed
  `pending_enlivens` keep their swissnum bytes on the gpa with precise
  per-row frees, because a bump arena cannot reclaim an evicted or removed
  row and would leak under churn. Third-party import **host designators**
  are interned in `key_arena` (session-lifetime; shared across rows that
  name the same introducing host) — only the listen cell is freed per row.
- **Version-neutral resolver-export link: one POD row per live listen
  (`Session.outbound_resolver_link`).** Bounded by the application's own
  listens (`engine.listen.listenOnPromise`, ADR-0095) plus V1.0's synthesized
  resolver mints, dropped when the answer is released on the outbound
  `op:gc-answers` path, and freed with the session. No owned bytes; the map
  backings are the whole cost.
- **Session-owned gift registry: gpa rows with per-row frees
  (`engine.bootstrap.GiftRegistry`).** Every `Peer` owns its CapTP session's
  deposits and scalar accepted/emitted handoff counters; `Peer.deinit` destroys
  all three. A withdraw resolves the still-open Gifter–Exporter session and
  borrows that peer's registry, so closing either required `Peer` destroys its
  rows without Host-wide replay or gift maps. Failure remains closed while no
  replacement session reuses the same names; ADR-0097 owns fresh keys and
  reconnect-incarnation isolation. A re-deposit of the same session-local gift
  id replaces the prior row by freeing its recipient key and gifted reference.
  The rows live on the gpa with precise per-row frees,
  never in a bump arena (an arena cannot reclaim an overwritten row and would
  leak every re-deposit). Each deposit dupes the gift id. A provenance-only row
  also dupes its recipient key, a verbatim-cap row adopts its gifted reference,
  and an exact local gift stores only the Vat target id. Validation and gift
  lookup borrow an immediate withdrawal; the inbound handoff is materialized
  only when it must park across the frame lifetime. An already-deposited gift
  still builds the ordinary owned
  outbound message before mutation. Only after that message is queued does an
  infallible commit remove the gift, free its id/recipient key and original
  payload, and record the count. An early verified receive records its count
  when the bounded pending row is admitted, before waiting, and reuses that
  accepted counter when the gift arrives. Queue OOM rolls back a fresh Port
  projection and leaves the gift retryable. A session registry pins neither a
  capability nor a row per handoff it has already served; replay stays blocked
  by the session's monotonic accepted count, not a retained marker. Because a
  consumed row is gone, the row count _is_ the live-gift count, so
  `max_deposited_gifts` bounds
  `gifts.count()` directly — no parallel counter to drift — and a node that has
  served many completed handoffs keeps accepting new deposits.
- **Parked withdraw: one compact verified claim per early
  `withdraw-gift` (`Peer.pending_withdraws`, ADR-0100).** The exporter resolves
  the give's gifter session, verifies both signatures and the receiving-session
  names, then advances the receiver session's replay counter before it waits. A
  verified receive whose gift has no live deposit must outlive the borrowed
  frame that carried it. The parked row therefore retains only its handoff
  count, fixed recipient/gifter/session names, and one exact owned gift id. It
  does not retain either signature, the exporter locator, receiving names, or
  the raw signed envelope. Exact gift-id bytes across all parked rows share the
  session's `max_frame_bytes` cap, in addition to `max_pending_withdraws`; either
  overflow is a loud `PendingWithdrawCapExceeded`. `Peer.step` retries the
  accepted claim without rejecting it as its own replay and frees its gift id
  when it settles; teardown frees the rest.
  Refusing the early withdraw instead would break the protocol's
  deposit-may-arrive-second contract, which the upstream OCapN suite pins.
  `Node.handoff_waiters` is authority-neutral scheduler state: one outer row per
  Gifter–Exporter `PeerId`, one gift-group row per 128-bit BLAKE3 tag, one inner
  row per receiver, plus at most one queued change per gift group. The fixed-size tag prevents an
  attacker-selected gift-id length from being copied into coordination state;
  exact signed bytes and the registry key remain the authority, so a collision
  only causes an extra bounded retry. Each receiver groups its pending rows by
  the same key. Admission reserves this relation before replay commits;
  settlement or receiver teardown removes it. The first group can allocate both
  nested map backings and changed-list capacity; later deposit and close marking
  allocate nothing. Removing the final group frees the outer map and
  changed-list backing; while any group remains, those tables and each live
  group's receiver map may retain their historical peak capacity. The Host
  reserves one dirty-FIFO slot and one flush plus one close action slot per live
  session when the shell is minted. It consumes one exact change and drives its
  receivers before taking another, so each Peer needs one scalar wake rather
  than an allocation-bearing queue. Deposit work is proportional to receivers
  waiting for that gift, and each receiver looks up only that gift's pending
  group; gifter close is proportional to that gifter's live groups. The FIFO
  backings retain the Host's historical peak live-session capacity until Host
  teardown.
- **Actor roots and reclamation (ADR-0101).** Each Vat actor row carries one
  `u32` root count; the alias row, the Host capability slot, each Port's
  export binding, and each exact gift row hold one root apiece, transferred
  and released at the seam that owns the relationship, and the owning spawn
  verbs transfer the spawn root into the capability slot with no eager export
  binding (wire positions mint at first marshal, and a same-side send routes
  to the Vat actor directly, minting nothing). Root zero retires the row —
  deferred past any running frame — and parks the box on the ADR-0060 retired
  list, freed at the outermost-turn boundary; on reservation failure the row
  stays, a bounded leak, never a dangling box. Queued turns hold no root and
  take the typed `NoSuchActor` refusal. Replacement and `unpublish` change
  discovery only (the registry is the one discovery authority; a fetch leaves
  no per-session alias copy) and release just the alias root, so a displaced
  actor lives exactly as long as its other relationships.
- **Listener fan-out: POD fire carriers over the stored resolution or a live
  object export; zero payload copies.** When a promise with N listeners
  resolves, each fire is queued as one POD carrier (`engine.Outbound.listener_fire`,
  whose `target` names the store holding the resolution — an inbound answer or a
  relayed third-party import — or a live object export's `fulfill(near)` via
  `FireTarget.near_object`, which needs no store row). `Peer.step` borrows a
  stored resolution back at encode through the one keyed lookup
  (`Peer.resolveFireStore`, over `peekResolution` or the imported-promise row),
  or rebuilds the near fulfill from the export position when the export row is
  still live. Queue-time session accounting runs on a borrowed stack message
  (`engine.pipeline.borrowedListenerFire`) in the sent-resolve order
  (reserve-then-record-then-push), so the wire-delta retains commit before the
  infallible enqueue — and those early retains are load-bearing, not just
  bookkeeping: they pin the payload's `near` exports across the queue→encode
  window against a legal partner `op:gc-exports`, which is why fire accounting
  cannot move to encode time. Store-backed carriers are stamped with their row's
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
  ships. `near_object` fires drop when the export row is gone at encode
  (export positions are never reused, so no row-id stamp is needed). Pinned by
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
- **Boxed handoff argument: the handoff arm of `view.zig`'s `Argument.toOwned`
  (one alloc per `desc:handoff-*` _argument_).** The owned `Argument.handoff` arm is
  `*Handoff`, not inline: a handoff payload is the largest arm by far and would
  otherwise set the size of _every_ `Argument`, so an ordinary integer arg in a
  deliver list would pay for the handoff arm it never uses. Boxed, `Argument`
  holds at 40 bytes and `Resolution` at 48, and those are a gate rather than a
  measurement: `src/ocapn/model/mod.zig` asserts the ceilings at comptime, so
  un-boxing fails the build. `bench/frame_view_bench.zig` prints the same
  numbers as `model_layout` but proves nothing on its own. The cost is
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
  `max_local_deliveries`. Named, not measured: the cap has a test, the
  one-allocation count does not.
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
  There is no clone of the resolution anywhere on the single-store relayed
  path (named, not measured: its two sibling claims have dedicated budget
  tests, this one is held by behavior tests alone). The introducing-session proxy (`Node.proxyForeignPromiseFulfill`)
  keeps **one** home `op:listen` per home wire (shared across recipient
  introduces). Host peek then one `toOwned` makes the Node the fire owner;
  N=1 **moves** into `applyRelayedResolution`, N>1 each recipient store
  materializes via `materializeResolutionForStore` — never a public
  `cloneResolution` spine and never N home listens. A late `op:listen` fires
  the same way, from the store; the stored resolution is freed once (on
  import GC co-eviction or session teardown). A fulfillment naming a bare far
  object takes the handoff arm instead of the store
  (`Node.giftRelayedCapability`): one `enrollForeign` token for the capability,
  then per recipient one pending-gift row, one queued `need_gift_id` action,
  and one decoded give boxed into a `model.Handoff` that recipient's store
  owns (`Peer.applyRelayedHandoffGive`). Per recipient, not per capability,
  because a give is signed for one recipient's session key; the minted give
  bytes are freed as `originateGive` returns, and each boxed handoff is freed
  by the store's single-owner path. The enrolled token's row is the named
  permanent cost: nothing above the node ever sees it, so unlike a fetched
  capability's token there is no `Host.gcRelease` that can drop it, and it is
  freed with the home peer. That is also what makes the deposit safe — the
  import cannot be released between the enroll and the later `provideGiftId`
  that deposits it. Bounded by the introductions the application itself makes,
  and by `Node.max_proxy_recipients` per home promise. Every other
  session-scoped shape — a
  promise, a near, a capability nested in a container — settles broken, with
  one gpa dupe of the reason per recipient through `Node.breakRelayedSlot`,
  because each store owns what it holds. All of it is bounded by the proxy
  row's recipient count, and the refused resolution itself is freed at the
  refusal.
- **Sturdyref enliven dedup: one swissnum dupe per in-flight row (ADR-0012).**
  `Session.notePendingEnliven` `dupe`s the swiss-number into a session-owned
  pending row; on fulfillment the pending row's swissnum _moves_ into the
  resolved cache (no second dupe). `cacheSturdyrefEnlivenment` still `dupe`s
  when no pending row exists. The resolved cache stores only the
  `(import_position, kind)` POD alongside it, never a clone of the enlivened
  reference. A side `StringHashMap` (swissnum → FIFO index) keeps
  lookup O(1) and stays in lockstep on insert and eviction; a reverse answer →
  swissnum index borrows the same owned slice for settle-side lookup (the
  `driver_core` enliven bridge keys on answer position only). `engine.sturdyref.recordEnlivenment`
  _moves_ the fulfilled `Reference.far` out to the caller (POD `FarRef`, no heap)
  and copies just its `import_position` + `kind` into the cache. The cache is
  non-load-bearing: an overflow evicts the oldest row and frees its swissnum. A
  failed insert is swallowed because a miss costs one extra bootstrap-fetch
  round-trip, not correctness. Each owned swissnum is freed once on
  overwrite-evict, `finishPendingEnliven`, or `Session.deinit`.
- **Host session-pair indexes: gpa maps with precise per-row frees
  (`driver_core.Host.partner_by_side`, `dialed_by_designator`, ADR-0012).**
  O(1) dial and post-handshake partner-key refusal at the 500k-connection Host
  tier (ADR-0076). `partner_by_side` stores the OCapN side derived from each
  verified partner key and routes an early withdraw to the live gifter session.
  `HostSession.indexed_partner_key` retains the exact key so a side-name lookup
  confirms key equality and unindex remains O(1); there is no second key-index
  map. `dialed_by_designator` borrows each dialed session's `role.dialed` bytes,
  reserved at mint and inserted at enroll. Both maps clear on unindex, condemn,
  or release — never a bump arena, because rows leave individually. They are
  bounded by live non-condemned sessions.
- **Host connection identity: one owned byte block per `HostSession`
  (`driver_core.Host.mintShell`, ADR-0098).** The sturdyref peer check needs the
  actual connection transport; the partner's signed locator cannot supply that
  fact. A dialed shell copies the transport and selected designator into one
  allocation, replacing the designator-only block it already required, so the
  check adds no dialed-session allocation. An accepted shell owns one block
  containing its transport symbol. The slices are borrowed by session indexes
  and freed together only after unindexing. The byte count is the caller's
  transport plus, for a dial, its selected designator; no hints or complete
  locator are retained here.
- **Import identity memo: one lazily-created map per session
  (`session.ImportTable.identities`).** A live import row may carry the
  node-unique routing token from ADR-0069, the opaque Host capability id from
  ADR-0096, or both while the application surfaces migrate. Both identities
  must die with the import row: the partner may reuse a released numeric
  position, and a memo outliving the row would revive the previous object.
  The same 24-byte value also counts how many wire retains have been surfaced
  as Host handles, so one borrowed reference cannot be lifted repeatedly into
  matching GC authority. The map remains behind one pointer and null until a
  row needs either identity, preserving the ordinary session's one-word,
  zero-heap cost. Its rows are bounded by the import table cap and freed with
  that table.
- **Host capability registry: one reusable slot plus three Host-wide indexes
  per live lifted target (`driver_core.capability.Registry`, ADR-0096).** The
  canonical target index makes repeated observation of one live import reuse
  one Host id; the id index rejects stale ids and raw ids minted by another
  Host; the intrusive peer list makes session close invalidate only capabilities
  homed there rather than scanning every Host row. A first remote lift can
  therefore allocate six times: slot storage, target index, id index, peer-head
  index, the import identity-map owner, and that map's backing. A
  repeated lift and every lower allocate zero. Each reusable Host slot is held
  to 80 bytes and each import identity row to 24 bytes by comptime budgets.
  Final release removes the target and id indexes. The C adapter maps one
  process-wide monotonic source through a process-keyed 64-bit permutation, so
  two Hosts never issue the same opaque scalar, adjacent mints do not expose the
  sequence, and retirement never makes an old scalar live again. Native scoped
  refs use a Host-local monotonic source and likewise never reuse an id in that
  Host. A custom issuer's zero or live-id collision retries before publication
  under a bounded retry count. Session close removes the same rows
  through the peer list. Slot storage keeps
  the Host's simultaneous-live high-water capacity, while target and peer rows
  are removed precisely, so ordinary capability churn retains neither live
  authority nor per-release tombstones. Model-to-C projection records each
  successful lift so a later allocation failure can roll the whole partial
  projection back with an exact wire GC release. Unsupported model arms are
  rejected by a complete preflight before the first lift. The
  common path holds eight receipts on the stack; a value carrying more than
  eight references spills one receipt array into the projection's existing
  scratch arena. This is **name**: rollback must remember the exact completed
  lifts, and recording them in the same traversal avoids a second tree walk.
- **Freed export ranges: one `u64` queue per node
  (`engine.Node.freed_export_bases`).** Each session gets a disjoint export
  range carved out of the node's own slot, so the ranges are a fixed budget: a
  node that never took a released session's range back would spend its slot by
  churning connections alone, and then either refuse every new session or carry
  into the next node's numbers. `Node.removePeer` gives the range back, reading
  it off the peer that held it, and `takeExportBase` hands out the oldest freed
  one before drawing a fresh one, so the slot bounds *live* sessions rather
  than the node's lifetime. The draw and the return sit on the same side of the
  boundary, which is why no layer above keeps a copy of a session's base. Oldest-first
  because reusing the range just freed would seat a new session on a released
  one's numbers immediately. Read from a cursor and compacted in place once the
  handed-back prefix outgrows what is still queued, so capacity tracks the
  ranges actually outstanding, and freed with the node. The give-back is
  best-effort: the release path has nowhere to report an allocation failure to,
  and a range that fails to return costs one slot out of a million, never
  correctness.
- **Canonical set ordering: encode-once per set element on outbound encode.**
  A set is unordered, so its wire form must not depend on the order the model
  held it in; canonical order is defined over _encoded bytes_. Syrup encodes
  each element once, sorts the encodings, and appends them
  (`writeCanonicalSet`). Cap'n Proto matches that shape: encode each element
  into a scratch builder, sort by the finished message bytes, then graft the
  encoded subgraph into the list (`encodeArgumentSetList`) — no second model
  walk. Syrup struct encode pays the same per-entry encode-then-sort
  (`writeCanonicalStruct`); a hinted locator's hint dict — once per keyed
  start-session, never per turn — pays it too (`writeHintDict`); capnp struct
  ordering is cheaper (shallow entry copy sorted by raw key bytes). All of it
  is turn-scratch bounded by the caller's own message and freed before encode
  returns. Deleting the key encode means sorting on model values, which two
  encoders can disagree on; the bytes are the only order both sides reproduce.
- **Inbound Cap'n Proto set uniqueness: view hash/equal, no `toOwned`.**
  `checkInboundSetUniqueness` folds borrowed set elements with
  `viewArgumentHash` / `viewArgumentsEqualBounded`; small sets stay on
  the stack so the common deliver path never grows `recv_scratch` past its
  retain limit, and every comparison visit charges the turn's
  `max_compare_visits` allowance so a wide equal-hashed pair cannot buy
  unbounded CPU. Syrup still refuses duplicates at decode.
- **Redeem dial parts: pending row sole owner; ticket-only HostAction.**
  `Node.acceptGive` parses the exporter URI once (`stagePendingDial`:
  identity + transport/designator/hint) and never keeps a verbatim URI copy —
  join / exporter-cache hits free the stage without opening a pending row.
  Unparseable locators fail closed at `acceptGive` via
  `error.UnparseableExporterLocator` with no staged heap — they never become
  a pending dial. Indexed by
  `pending_dial_by_identity` for O(1) join on identity, not raw spelling.
  Both `Node.Action.dial` and `HostAction.dial` carry only the ticket;
  Zig borrows via `pendingDial` / `PendingDialView` until `exporterDialed` /
  `dialFailed`. C exposes one `pancake_host_pending_dial` filling
  `PancakePendingDial` (transport/designator/hint) over that same view.
  Bridge redeem parks only the ticket (`OutboundConnect.redeem`); connect
  re-borrows the view at adoption. An empty hint is an unowned sentinel (not
  a heap `""` dupe); all free paths go through `freeDialPart` /
  `freeDialParts` / `freePendingDialShell`. No re-parse on the redeem dial
  path.

### Named Deferred Costs

- **Bridge app-dial transport/designator dupes.** `OutboundConnect.app_dial`
  owns copies for the connect window: `openDialedOver` needs CapTP partner
  transport/designator at adoption, and `Loop`/`Backend` retain only the
  resolved connect target (no OCapN parts to re-borrow). Redeem stays
  ticket-only and re-borrows `pendingDial` — it must not take this cost.
  Relocating the same dupes to the caller, Host, or Loop does not forbid
  them; keep the name here.
- **Binding dial OS-connect string.** After `pancake_host_plan_dial`, each
  binding decodes `host` / `addresses` once from a subslice of the input UTF-8
  buffers the plan aliases (the OS connect API needs a language string). That
  one decode is named; a second rematerialize via opaque FFI `readMemory` /
  `string_at` / `bytes<-c` of the same view is forbidden.
- **Binding outbound flush frame copy (TS / Python / Racket).** Those bindings
  copy managed-frame bytes then release before the async write; Rust holds the
  managed frame across the write (zero-copy). The copy is language/lifetime-
  forced for async FFI — do not "optimize" without a hold-across-await proof.
- **Racket inbound `pin-immobile`.** Every `feed_bytes` path pins the feed
  buffer into collector-immobile memory before the FFI call. The pin copy is
  the Racket FFI cost; the stream tail itself lives in the core session, so
  no binding-side coalesce rides on top of it.
- **Wasm linear-memory boundary (`bindings/ts/web/adapter.ts`, ADR-0070).**
  JavaScript cannot lend wasm a view of its buffers, so every buffer argument
  and `pointerOf` target pays one copy into linear memory, and each
  `SymbolDef.outBuffers`-marked out-parameter pays one copy back (an
  unannotated table copies every buffer back, the safe default; the fed frame
  chunk is annotated input-only, so a feed stays at one copy-in). A memoized
  re-stage re-syncs the copy so it always reflects the JS buffer's current
  bytes; do not delete that resync as an "optimization." Staged copies retire
  through a generational arena, freed two outermost-call windows later,
  because a call's returned views alias its staged inputs and a pre-call
  `pointerOf` result is the next call's input. At most two windows of
  stagings are live.

## Per-session footprint budget

The 500k-connection destination is a budget gated by the build (ADR-0045), so a
field added to session state is a withdrawal from it, not free. `engine.Peer`
carries a `comptime` ceiling on `@sizeOf(Peer)` (`peer_session_struct_budget_bytes`, 1104), and
`test/engine/footprint_budget_test.zig` holds a warmed session's core state at
or under 2 KiB per session. If your change trips either gate, the fix is to
weigh the bytes and raise the budget deliberately — in the constant and in
`docs/ladder.md` step 2 together (the ladder owns the numbers) — never to route
around the check.

The engine's four peer queues each bound their retained backing at
`steady_queue_bytes = 4096` (`src/ocapn/engine/mod.zig`): capacity a burst grew
above the bound is freed at the drain point, at the named price of one growth
re-allocation when the next burst begins. The actor layer holds the same
posture at Vat scale (file-level constants in `src/actors/vat/mod.zig`, shared
by the sibling vat modules). `steady_turn_arena_bytes` and
`steady_settle_arena_bytes` bound the two long-lived arenas at 4096 bytes.
Queue payload lives in independently reclaimable chunk arenas; an empty ingress
retains none, while the Vat keeps at most one spare chunk whose arena is bounded
by `steady_spare_arena_bytes` (4096). `steady_list_bytes` (4096) bounds the
`moved_replies` ArrayList and sets the fixed queue-row target, with the chunk
header separately measured. The pending-vow map is the scheduling-order-safe
price of refusing listeners for already settled local vows. The allocation
budget proves a warmed local queue batch performs zero general-purpose
allocations, and `test/actors/vat_footprint_budget_test.zig` holds a
burst-then-quiescent Vat back under the arena and one-spare bounds.

The session's inbound scratch arena holds the same posture with a deliberately
smaller bound. `Session.recv_scratch` materializes one turn's set-uniqueness
fold, owned-fallback message, and GC dedup, so a single admissible inbound frame
(up to `max_frame_bytes`) can grow it to several times that in owned
`Argument`s. `steady_recv_scratch_bytes = 384` (`src/ocapn/session/mod.zig`,
beside the field) bounds what each recv entry point's `reset(.retain_with_limit)`
keeps, returning a burst's peak instead of pinning megabytes per session for the
connection's life. It is smaller than the 4096 above because the session answers
to the 2 KiB core-state budget, while the actor arenas belong to the one
Host-wide Vat. The session arena must leave room for the tables beside it.
`test/engine/deliver_set_scratch_budget_test.zig` holds a big-set frame's scratch
back under the bound.

The completion loop wraps each `Peer` in one `Conn` slot — the unit it allocates
`max_conns` of — so that wrapper carries a ceiling of its own: a `comptime`
assertion in `src/net/completion/loop.zig` holds `@sizeOf(Conn) -
@sizeOf(engine.Peer)` at exactly `conn_slot_overhead_bytes` (128) — an equality,
so a field added to `Conn` fails the build rather than spending headroom nobody
is watching — isolating the
wrapper's bookkeeping from the `Peer` the one-kilobyte ceiling already guards.
The number moves in the constant and in `docs/ladder.md` step 2 together, like
every other footprint gate.

The byte-fed host tier (ADR-0076) adds the third per-connection static
allocation: `driver_core.mintShell` wraps each `Peer` in one `HostSession` shell,
which embeds a `Served` Port while the Host owns one shared Vat and the `Peer`
lives behind a pointer. A `comptime` assertion in `src/driver/core/host.zig`
holds `@sizeOf(HostSession)` at or under `host_session_struct_budget_bytes`.
The Host session ceiling is 496 bytes; narrower targets may be smaller. It
fell from 768 when the Vat moved to Host scope, banking 304 bytes per
connection (the 448-byte Vat is charged once per Host), then rose by 32 for
ADR-0097's per-session signing seed — key material that is per-session state
by definition. A field added
to the shell or `Served` therefore fails the build instead of silently growing
every connection at 500k. The number moves in the constant and in
`docs/ladder.md` step 2 together, like the `Peer` and `Conn` ceilings beside it.

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
