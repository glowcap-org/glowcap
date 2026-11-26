# Host memory costs

Derivations live at each declaration, and this inventory names Host runtime and
custody costs.

## The ledger

- **Selected TypeScript reply tracking**: [withGc](../../../../bindings/ts/runtime/promise.ts)
  selects the existing Host vow row before observation: one lookup, no payload
  copy or C retain. A manual outcome uses the existing
  [argument walk and reference registration](../../../../bindings/ts/runtime/gc.ts)
  per capability occurrence; an already tracked row skips both. The first
  tracked reference creates one Host-wide FinalizationRegistry, whose targets
  remain the shared wrappers until collection or explicit release.

  A local promise adds one intent bit to its existing state, and an await-only Host promise
  keeps its Host owner beside the vow id; neither adds an adapter object or
  closure. Unexposed, discarded outcomes use the same argument walk to disarm
  tracking and append one id per occurrence to the existing release queue,
  then schedule once without creating finalizer registrations.
  [Fetch completion](../../../../bindings/ts/runtime/promise.ts) transfers
  rejected values to that same queue; valid results keep their release policy.

  A progress failure adds one settlement continuation and its derived promise
  to the existing outcome record until a late value can enter that same release
  queue. Successful waits add neither cost.

- **Tasks application mutation ordering**: the
  [TypeScript board](../../../../apps/tasks/deno/task_client.ts) keeps one
  promise tail per membership, with operation and recovery reactions for each
  change through its reply. The [Rust board](../../../../apps/tasks/rust/board.rs)
  holds one inline Tokio mutex, while the
  [Python](../../../../apps/tasks/python/task_client.py) and
  [Racket](../../../../apps/tasks/racket/task-client.rkt) boards allocate one
  lock or semaphore per membership. Contending calls use their runtime's
  waiter storage until entry or cancellation. These application gates avoid
  reusing a receipt sequence for distinct actions, copy no payloads, and leave
  reads outside the gate.

  Watcher startup rollback uses the existing error context of each language.
  A double failure in Racket allocates one application exception that retains
  both originals and the startup continuation marks until its caller drops it.

- **Generated TypeScript reply work counter**: `emit` in
  `tools/interface/typescript_compounds.zig` emits one temporary DecodeBudget
  object per compound observation. Recursive helpers share it until return or
  refusal. The budget prevents unbounded decoding without cloning arrays,
  Tagged records, payloads, or capability wrappers. The template declaration
  owns its lifetime derivation, and direct emitted tests preserve identity.

- **Generated TypeScript observation**: `Pending` in
  `tools/interface/templates/pending.ts.in` observes through the original raw
  promise. Its `then` method adds a chained promise so decoder failures reach
  the awaiter's rejection callback. No reply or capability wrapper is copied.

- **Projected actor events**: `Port.prepareProjection` creates one
  `Event.ActorCustody` link at the first projection. The last owner frees it.
  A transferred event can outlive its Peer, which detaches this link before
  tearing down the session. `Event.holdProjectedActors` takes one local hold
  per projected object occurrence in the admitted frame. Disposal revisits
  the frame's immutable parse with its admission stamp, so a reused position
  cannot release another object. Each event adds a nullable custody pointer
  and a 64-bit stamp, with no per-event allocation.

  The export row's existing purpose union holds the stamp, local count and
  release-queue links within the existing 48-byte row. The table stores two
  32-bit values for the ready head and projection count. A Port binding
  stores one link to its next alias.
  Disposing a projected binding takes constant time regardless of alias count.

  A local turn whose arguments name a projection holds those occurrences in
  `Queued.Held`. Its record lives in the queue chunk's arena and spends the
  same ingress byte budget as the message. Plain local deliveries keep their
  original queue row and storage.
- **Borrowed callback capabilities**: `HostTurn.retainArguments` keeps incoming
  identities live through reply consumption. A capability-bearing input adds one
  five-word turn-arena node (`ArgumentLease` plus `ResourceCleanup`), with no
  Value copy or per-occurrence receipt allocation. One pointer per Vat owns the
  cleanup chain. Declaration assertions and the Host footprint test pin these
  charges.

  The stable tree is the retain rollback inventory. Refusal releases immediately;
  a top-level wire serve releases after reply consumption. Near-call custody lasts
  until the next outermost turn or Vat teardown.
- **Host face wires**: `driver.HostRuntime`'s `Wire` (ADR-0018, ADR-0024). One
  shell per session, freed only by its owner.
  - Every link is a resident connection. It feeds the core from a lending
    resident's own receive, or reads into the one
    `HostRuntime.resident_read_scratch` when the resident only copies, so an idle
    resident wire holds no read buffer.
  - Protocol admission stays independently bounded by `frame_cap`: a larger
    frame assembles in the core's bounded spill instead of making every live wire
    retain the maximum.
  - A link may retain one outbound frame across a full write window, an owned
    transfer from `takeOutbound`, resumed at its offset on `ev_writable`, never a
    copy.
  - Inbound that arrives before the embedder attends the session is copied
    once into the link's `parked` buffer, bounded by
    `unattended_parked_cap_bytes` and freed when the session is attended. A
    message-framed wire keeps each packet behind its length in that buffer,
    with no allocation per packet.
  - An EOF marks the wire closed and breaks its vows **without freeing**, because
    a view still holds the pointers: the close-and-release split.
  - Wait scratch, `HostRuntime.poll_scratch` and `HostRuntime.extra_fd_scratch`:
    construction and each resident admission reserve one row per distinct
    resident plus the mailbox and stepped wakes, so the descriptor-poll wait and
    the terminal signal wait build their rows without allocating. The reserve
    grows by the list's amortized step (8 bytes per poll row and 4 per
    descriptor row), so retained bytes exceed the logical rows, and a
    refused reserve leaves earlier growth in place.
  - Parking watches: a parking branch hands its parker each sibling, mailbox,
    and stepped wake descriptor once. `HostRuntime.watched_siblings` and two
    flags are the whole bookkeeping, so the runtime allocates nothing there.
    The inline marks reduced `HostRuntime` by 24 bytes in an aarch64 Linux
    Debug test build with Zig 0.17.1. Each provider owns the
    storage its `watch` callback needs. A refused watch is retried on the
    next wait.
  - Ready query rows, `Drive.Stepped.ready_query` (`net.readiness.ReadyQuery`):
    a stepped runtime whose descriptor poll is refused asks its ready set which
    members are ready, in zero time, and the set's membership is residents plus
    `watchFd` descriptors plus the two wakes (`providers.wait_signal_rows`). A
    set of at most 32 members uses a 512-byte stack buffer and allocates
    nothing. A larger one reserves its rows at resident admission and at
    `watchFd`, before either publishes to the kernel, so the refusal path
    allocates nothing. At 68 members the list holds 110 rows, 1760 bytes
    (16-byte rows on aarch64 Linux). The query adds 32 bytes to the stepped arm,
    and so to `HostRuntime` on both faces (48 bytes together with the due
    below, Debug aarch64 Linux: 1544 to 1592 bytes in the integrated layout probe).
- **Pending open rows**: `HostRuntime.startDial`, a resident listener's
  accept, and the redeem drain into `HostRuntime.stageDial` (ADR-0024). One gpa
  row per in-flight dial or accept, carrying stage, outcome route, and, for a
  redeem, the verdict it owns until the core commits it (the open session or the
  exact failure). Active stages own their handshake deadline, and report stages
  own none.
  An application row owns a cloned locator for retries; a redeem row rereads
  the core route and owns no locator bytes.
  - The shared `max_pending_opens` admission bound limits these rows and their
    pre-open sessions/wires across every route. A blocking dial consumes the same
    counter while it pumps without owning a row, and an arrival over the bound
    closes with no session.
  - Rows are heap-owned and removed before their settle notification runs, since
    a notification may stage further dials and a list realloc must not move a row
    mid-sweep.
- **Driver accept queue**: `driver.Server.accepted` (ADR-0018). One ring of
  Session pointers reserved at construction, bounded with handshake reservations
  by `max_pending_opens`. Wrappers allocate at publication and transfer to the
  caller at accept. The queue allocates nothing and copies no payloads in a turn.
- **Lower and lift boundary**: `driver.Session` (ADR-0026). One
  `Session.verb_scratch` arena on the way down (spines only, leaves stay
  borrowed), reset at each verb's entry under `steady_verb_scratch_bytes` the
  way the C host tier resets its own, so a steady stream of verbs allocates
  nothing after the first. The caller's arena serves the way up, with
  capability rows under rollback receipts. **The lift aliases the settle
  capture instead of re-cloning, which is why `Reply` is arena-only and carries
  no `deinit`.**
- **C bridge argument spine**: `viewsToC` in `c_abi/shared/value_to_c.zig`,
  called from `hosted_behavior.handleOwned`. A C-hosted object's callback
  arguments for a capability-free deliver are one `GlowcapArgument` array per
  container in the turn arena, built straight from the wire views with no Host
  value tree. Byte leaves stay lent from the frame. A deliver that carries a
  capability takes the lift instead.
- **C bridge reply spine**: `HostedBehavior.callAndReply`. A served C reply is
  one `Argument` array per container in the turn arena with every byte leaf
  lent from the consumer's reply storage (`marshal.hostArgumentFromCLent`).
  The answer store makes the one copy of the leaves. The consumer keeps its
  storage valid and unchanged until the library call that ran the callback
  returns or a behavior callback is entered again, whichever comes first. A `.local` or `.eventual` turn copies the leaves into the arena
  (`marshal.hostArgumentFromCOwned`), because its caller keeps the value, and
  a turn that forwarded reads no reply.
- **Integers copied for a handler**: `driver.Args.integers` (ADR-0010). A
  list of integers the Cap'n Proto codec left on the wire as a word run is
  lent to the handler as a typed slice with no copy. On Syrup, on a lifted or
  local delivery, and on a host that cannot read little-endian words as they
  lie, the accessor copies the integers into the turn arena once per call,
  so the handler keeps one contract and the copy dies with the turn.
- **Settle capture**: one `model.cloneArgument` or broken-reason dupe per
  blocking wait (`driver.Session.call`, `driver.Promise.settle`, `SettleCapture`).
  Severs the turn-borrowed resolution so the returned `Settled` outlives the
  drive. `fetch` and `enliven` stay allocation-free.
- **Unobserved vow completion**: `queueVowCompletion` materializes one owned
  Host Value with one retain per capability occurrence (ADR-0007).
  - Bytes and spines copy once into its arena. Scalar and cached capability
    results need no arena backing.
  - <!-- value ../../../../src/driver/core/host/capabilities/lift.zig inline_capacity -->8<!-- /value --> lift receipts stay inline. Spill uses temporary Host storage freed
    before publication.
  - A drained completion moves to its vow row without another clone
    (`holdDrained`). The Zig Session's drive keeps its retains there, and
    `takeHeld` clones the reply once into the caller's arena when `settle`
    reads it, for a reply no listener awaited.
  - Actions move through drains and parked tables without another clone. Their
    inline arena state, the diagnostic presence word of a local completion (it
    has no originating peer), and archive-neutral turn failure text add inline
    bytes to actions, the Host, and the Vat. Sessions gain none.
  - Projection acquires consumer retains without scratch allocation and rolls
    back a failed prefix through the stable tree.
  - `completion_test.zig` covers allocation refusal and the spill boundary.
    [`admission_test.zig`](../../../../test/driver/core_host/admission_test.zig)
    pins the Host and action sizes and says what each word is for.
  - Every mint reserves its FIFO slot, so publication cannot strand a completion.
- **Settle mailbox**: `driver.SettleMailbox` (ADR-0014). Fixed slots at init, so
  a worker's `post` allocates nothing. One boundary clone into the slot's arena,
  refusing `ValueTooLarge` and `MailboxFull`. Backpressure, never growth.
- **Loop-archive dial and events**: `glowcap_driver_dial`,
  `glowcap_driver_next_event` (ADR-0024).
  - A dial projects the borrowed locator only for its call and starts the
    provider immediately. The nonblocking provider contract lets the loop retain
    no locator copy.
  - Admission reserves one event slot per externally observed open, so OPENED,
    OPEN_FAILED, and ACCEPTED callbacks append without allocation. Error names
    are static.
  - A completion action is the one owned event payload, moved from the drain
    through the completion sink without a re-clone, projected with the byte-fed
    queue's own scratch and freed through `Host.freeAction`.
  - Session events carry a peer id beside the pointer, so release invalidates
    them in O(1) and drain skips stale rows without touching freed memory.
  - Sink and close-observer appends remain best-effort under allocation failure,
    named at their declarations.
- **Host session indexes**: `Host.partner_by_side`, `Host.dialed_by_target`
  (ADR-0007). O(1) dial and partner-key refusal at the 500k tier, on the gpa with
  precise frees, because rows leave individually.
- **Session close timing**: `Host.session_close_timing` (ADR-0030). One gpa map
  row per finite-grace session close, removed at `Host.markSessionTerminating`
  or tolerantly at `freeSessionShell`. Cancel and unbounded finishes pay
  nothing, so an open session stores no deadline. The timing lives out of line
  for that reason, argued at the declaration.
- **Parked Node actions**: `Host.parked_node_actions` (ADR-0017). One gpa
  row per recipient whose outbound pressure refused a Node action, holding
  the actions moved off the shared queue with their payload intact
  (`Node.parkPeekedAction`), so one partner's flow control holds back only
  what is bound for it.
  - The seat an action returns to is promised before it leaves the queue, so
    every fallible step precedes the take.
  - The return through `Node.pushParked` (on the next take of that recipient's
    outbound bytes or at its release) never allocates.
  - Out of line, so a session under no pressure pays nothing.
- **Host session locator identity**: `Host.mintShell` (ADR-0007). One owned block
  holding the transport (and, for a dial, the selected designator), because the
  sturdyref peer check needs the actual session transport and a signed locator
  cannot supply it. Replaces a block the dial already required, so it adds
  nothing.
- **Resident retry deadline**: `HostRuntime.resident_retry_due_ms`. One
  optional `i64` deadline (`HostRuntime` 1552 to 1568 bytes, debug aarch64
  native), separate from the core's `memory_retry_due_ms`, armed while
  any resident's `memory_retry` group reports `owes`. It reuses the shared
  `memory_retry_ms` interval with its own epoch, so a core retry never advances
  it and a joining debt never postpones it.
  - The due pass queries and retries residents in place, with no list copy and
    no per-listener clock, before the core's gate. A terminal failure clears
    the deadline without querying.
  - The common case, no debt, still pays a live `owes` scan.
    `reconcileResidentDebt` runs at every operational attempt exit and at the
    `flushResidents` tail: one optional group check per registered resident,
    and one indirect `owes` call only for a resident that declares the group.
  - A completion resident answers from its debt count and reads its failure
    state only when the count is nonzero. The scan stops at the first that owes
    and allocates nothing.
- **Descriptor refusal due**: `HostRuntime.descriptor_refusal_due_ms`. One
  optional `i64` deadline (16 bytes of the growth above), armed by a descriptor
  poll the kernel refused for lack of memory and cleared by the next poll that
  succeeds or by the first transition to terminal.
  - It paces the wait that met the refusal to one `memory_retry_ms` interval
    from a fresh clock reading, never postponed by a later refusal. It is
    separate from the core's and the residents' debt, so neither a core retry
    nor a zero-timeout step advances it.
  - A live due holds the poll off as well. The wait makes no raw descriptor poll
    until the due and takes the ready-set query (stepped, operational) and the rest
    instead. At the due it polls once, clearing on success and arming the next
    due on a fresh refusal.
  - The rest runs with cancellation held off for its length alone, against the
    deadline the wait's bound named at entry, and allocates nothing.
  - Steady cost: a positive wait reads the runtime clock once at entry and `net.poll.wait` reads the kernel clock
    to preserve its deadline across interrupts. A zero wait reads no clock while no due is armed. Under
    a due every wait, zero included, reads the clock and skips the descriptor poll until the due.
    Operational stepped waits still query the ready set.
- **Advertised locator custody**: `retainCanonical` in `engine/node/locators.zig`
  makes the sole Node-owned snapshot before replacement. Host preparation borrows
  input and `HelloHints` scratch through that copy. `Host.prepareAdvertisedLocator`
  returns an independent owned value when its caller needs a longer lifetime.
  `bench-host-locator` measures traffic. The driver budget holds replacement and
  allocation-free repeated accept fallback, with aliased input and OOM rollback.
- **Import identity memo**: `session.ImportTable.identities`. **Both identities
  must die with the import row**, because a partner may reuse a released position
  and a surviving memo would revive the previous object. The row also counts
  surfaced retains, so one borrowed reference cannot be lifted repeatedly into
  matching GC authority. Behind one pointer and null until needed.
- **Host capability registry**: `driver_core.capability.Registry` (ADR-0026).
  Three indexes so a repeated lift reuses one id, a stale or foreign id is
  rejected, and session close scans only capabilities homed there.
  - Six allocations on a first remote lift
    (`test/driver/capability_registry_test.zig`), zero on a repeat or a lower.
    <!-- value ../../../../src/driver/core/capability.zig slot_budget_bytes bytes -->80 bytes<!-- /value --> per slot and `identity_budget_bytes` per identity row by comptime budget.
  - Ids never come back: a process-keyed 64-bit permutation over one monotonic
    source.
  - Projection records each lift in a receipt so a later failure can retire
    it. Two receipt flags mark a retain taken from a held-back import row and
    a provisional settled-data row, and both fit the receipt's existing
    padding. Partner and queued input roll back through an exact wire GC
    release. Borrowed input undoes only its own claims and sends nothing. The
    receipts stay on the stack before spilling, and the transaction keeps the
    allocator it spills into beside them. That is the caller's arena for every
    lift whose values the caller keeps (`liftView`, `liftValues`, `projectValue`,
    `projectValues`), whatever its input custody, and Host storage only for
    `ownValue`, which owns its result.
  - The settled data an answer reference reads joins a borrowed lift's
    receipts and shares their inline capacity, so a refusal undoes it with no
    second walk or copy. A repeated observation of one redeemed route finds
    the route already consumed and checks, by an assertion-only lookback over
    the earlier receipts in the batch, that one of them names it. The check
    allocates nothing and walks no value. A comptime guard on the receipt pins
    its layout.
- **Capability promise rows**: `Host.capability_promises` (ADR-0068). One
  gpa map row per inline handoff give under redemption, per partner answer
  lifted from an argument, and per Host vow passed as a capability, with its
  queued operations and per-session projections in two lists that grow on
  demand and are freed at settlement. A broken row passed on afterward owes
  one more projection until the pump breaks it.
  - A lifted answer holds one retain on the session's answer payload until the
    answer settles, so the stored resolution outlives the partner's GC of the
    position, and one Node action seat reserved at the lift
    (`Node.reservePromiseSettlement`), so the Peer publishes the settlement
    without allocating. `SessionLimits.max_lifted_answers` bounds the
    subscriptions per session, and the same answer lifts to one row.
  - A vow passed as a capability reserves the same seat when the promise is
    made, and the vow row names the promise (`VowRow.watcher`, one optional
    id). When the vow fires, the row takes its own copy of a data settlement
    (`Row.SettledData`) or its own lift of a reference, because the vow's
    settlement is consumed by the vow's listener and the promise outlives the
    vow handle. One vow passes as one promise.
  - A promise that settles to data owns the data in one arena on the row
    (`Row.SettledData`), lifted once under the origin session, held while the
    application holds the capability, and freed with the row.
  - A session vow row keeps the completion the embedder drained
    (`VowRow.completion`): the action's own value and arena moved, not
    copied, holding no capability retain, and freed when the handle is
    released. A vow asked for as a capability after it settled stages from
    it, retaining a reference for the promise or cloning data once into the
    promise's arena (`promise_answer.cloneData`), because the row keeps its
    copy for a later ask.
