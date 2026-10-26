# Host memory costs

The [memory ledger](../SKILL.md) owns the naming procedure. Derivations live
at each declaration, and this inventory names Host runtime and custody costs.

## The ledger

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
  - An EOF marks the wire closed and breaks its vows **without freeing**, because
    a view still holds the pointers: the close-and-release split.
  - Poll scratch grows once and then allocates nothing.
- **Pending open rows**: `HostRuntime.startDial`, a resident listener's
  accept, and the redeem drain into `HostRuntime.stageDial` (ADR-0024). One gpa
  row per in-flight dial or accept, carrying stage, deadline, and outcome route.
  No byte payload, because the locator is consumed at stage time.
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
  - Projection records each lift so a later failure rolls the partial projection
    back with an exact wire GC release. The lift receipts stay on the stack before
    spilling.
- **Capability promise rows**: `Host.capability_promises` (ADR-0068). One
  gpa map row per inline handoff give under redemption and per partner answer
  lifted from an argument, with its queued operations and per-session
  projections in two lists that grow on demand and are freed at settlement.
  - A lifted answer holds one retain on the session's answer payload until the
    answer settles, so the stored resolution outlives the partner's GC of the
    position, and one Node action seat reserved at the lift
    (`Node.reserveAnswerSubscription`), so the Peer publishes the settlement
    without allocating. `SessionLimits.max_lifted_answers` bounds the
    subscriptions per session, and the same answer lifts to one row.
  - A promise that settles to data owns the data in one arena on the row
    (`Row.SettledData`), lifted once under the origin session, held while the
    application holds the capability, and freed with the row.
