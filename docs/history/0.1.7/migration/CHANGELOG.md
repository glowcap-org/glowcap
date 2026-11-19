# Upgrading to 0.1.7

Read these changes before rebuilding a library client or provider, or
upgrading a Rooms deployment that holds saved state. The
[earlier changes in this release](../CHANGELOG.md#breaking) record the
first round of changes to these interfaces.

- An admitted C driver step preserves a terminal result through later steps
  and consuming release. Read callerless failures from the adopted Host's
  Context. Zig callers of `HostRuntime.stepAny` read the cause of
  `error.LoopTerminal` with `terminalFailure()`.
- Stream and multiplexed providers return `GLOWCAP_ACCEPT_ARRIVAL_FAILED` for a retired
  arrival (`.arrival_failed` in Zig). `giftIdFailed` returns delivery status. A send
  without a recipient yields `.unobserved_gift_failure` with the original cause.
- A failed drain write is the session's primary close failure. A later close failure is secondary.
  Add `GlowcapProviderFailure *out_failure` to `GlowcapStreamTransport.try_read` and `.try_write`, then rebuild.
  Both callbacks on Zig's `net.external_completion.VTable` take `*?net.carrier_failure.Report`.
  Supply the transfer's cause there. Reserve `conn_take_failure` for independent connection failures.
- Add a source parameter to Zig's `takeConnFailure`. Return the requested `.independent` or `.terminal_io` report.
  Set `failure_origin` to `.terminal_io` for shared terminal I/O or `.retired_arrival` for a retired accept.
- Create a Host with `glowcap_host_new_in` before `glowcap_driver_take_host`.
  Keep its Context alive until release consumes the loop. Adoption of a Host
  from `glowcap_host_new` returns `GLOWCAP_ERR_INVALID_ARGUMENT` and leaves
  it usable for byte-fed operation.
- A live session reports the provider's primary and secondary causes when a foreign stream's
  `conn_close` fails. Zig residents and external providers use the following close contracts.
  - `net.MultiplexedResident.VTable.conn_close` and `connCloseOutcome` take a
    `net.multiplexed_resident.CloseMode`, `.awaited` or `.no_wait`, which names
    who receives the provider's close result. Pass `.no_wait` from a call that
    does not wait. Either mode may still answer `.pending` while admitted
    bytes drain. The optional `conn_abort` and `connAbortOutcome` take the same
    mode: an abort delivers an already claimable result to that recipient.
  - A resident keeps the provider's handle for an `.awaited` caller only when
    it will publish `ev_closed` and return the result from the next `.awaited`
    call.
  - `net.external_completion.VTable.conn_close` is now a choice. Wrap an
    existing close as `.{ .plain = close }`. A provider that wants a live
    session to receive its close failure supplies `.{ .reporting = close }`,
    one function that takes a `CloseRecipient` (`.caller` returns the failure,
    `.sink` delivers it to the provider's own sink).
- Rust callers of the low-level driver now pass `&Context` as the first
  argument to `DriverLoop::open`. Keep the Context to read recorded failures
  with `next_failure` or `take_failures` after dropping the loop.
- A custom `net.MultiplexedResident.park` returns `net.MultiplexedResident.Park`.
  Replace `true` with `.woke` and `false` with `.timeout`. Return `.unavailable`
  before waiting if capacity prevents arming an optional wake watch. The driver
  polls its readiness descriptors then, and when `watch` returns
  `error.OutOfMemory` before arming a watch.
- On epoll, `submitPoll` now returns `error.EpollWatchLimit` for kernel
  `ENOSPC` and `error.OutOfMemory` for kernel `ENOMEM`. On kqueue it
  returns `error.OutOfMemory` for kernel `ENOMEM`. These refusals previously
  returned `error.EpollControlFailed` on epoll and `error.KeventFailed`
  on kqueue. The completion resident can skip an optional park on either
  capacity refusal. A transport that needs the poll still receives an error.
- A custom backend for `net.completion_resident.Resident` declares
  `readyPending(*const Backend) bool`. It reports whether the next `peek` can
  advance or surface a user-space completion or deferred fault. Adapters
  check their own queue first, then the wrapped backend. The method uses no
  allocation, I/O, locks, or waits. `completion.Loop` backends need no change.
- Recovering a room's manager link in Rooms is its own operation. The
  browser no longer reads the room's manager identity and sends it with a
  generic operator request. The session reads that identity from the room's
  seat, asks the operator once, and saves the link only into the room it was
  requested for. The operator may leave the workspace afterwards.
- A recovered link is saved after the seat is lost only while the room's
  original entrance (its link, accepted visit, or directory public entry) is
  still held. A room with no entrance is saved only while its original seat is
  still held.
- A recovery still unresolved or held when you upgrade cannot be finished by
  the new version: finish it before upgrading, or release it and request the
  link again. Releasing a held recovery does not revoke a link the operator
  already issued.
- `SessionAcceptObserver.opened` keeps its reservation on error. The runtime
  calls `abandoned` and `arrival_failed` in place of `failed`. Release it once, in
  `abandoned`. Handle `arrival_failed` as the retirement of one arrival with
  the listener still open.
- Add `try` when calling `net.completion.BufferPool.acquire`, which returns
  `Allocator.Error!?u16`. Null means every buffer is leased. A lazy allocation
  refusal returns `error.OutOfMemory`. A data receive whose allocation fails
  completes once with that error and retires only its wire. Signal and wake
  receives drain or re-arm.
- Values nest at most 64 deep on every path (`model.max_value_depth`), and
  one count decides it: a top-level argument sits at depth 0, a container's
  items one deeper, and any container at depth 64, an empty one included, is
  refused. `SessionLimits.max_nesting_depth` and the C marshal's separate
  ceiling are gone, so a Zig embedder deletes the field from its limits.
- A send to a promise past the ceiling, settled data included, is refused at
  the call instead of failing after it queues, and the Zig surface reports
  `ValueTooDeep`. Data that settles only after the send is admitted can
  still fail when it lowers, and that send's result breaks.
- A local send, a promise send, a queued admission, a settle, a Vat send, a
  Loam write, and the C marshal refuse a value past the ceiling with
  `ValueTooDeep` before admission, and the session keeps serving. A partner's
  frame past it stays `NestingTooDeep` and ends that session. Over C, such a
  value returns `GLOWCAP_ERR_INVALID_ARGUMENT` where it returned
  `GLOWCAP_ERR_UNSUPPORTED_VALUE` (or `GLOWCAP_ERR_SESSION` for a far send),
  so handle that code for depth. Zig callers of those boundaries that matched
  `NestingTooDeep`, `UnsupportedValue`, `UnsupportedArgument` or
  `MalformedView` for their own deep value match `ValueTooDeep`.
- A handler result past the ceiling that fails conversion before its turn
  commits (the C marshal and Host capability lowering) retracts the turn's
  provisional sends. A served turn that already committed keeps its effects
  and breaks only its answer with `ValueTooDeep`. Neither ends the session.
- Low-level Zig callers also change. `model.argumentIsPlainData` now
  returns `error{ValueTooDeep}!bool`, so call it with `try` or handle
  `ValueTooDeep`. Resolver `fulfill` and the settle mailbox's `post` report an
  over-deep value as `ValueTooDeep` instead of `ForeignArgument` and
  `NotPlainData`. Those errors remain for authority. The view materializers
  `toTreeDepth` and `toSliceDepth`
  take a trailing comptime `author` argument, `.local` for a value your code
  wrote (`ValueTooDeep`) or `.partner` for wire data (`MalformedView`).
  Clones and measures of owned values now report `ValueTooDeep` for depth.
- `Host.liftValue`, `liftView`, `liftValues`, `projectValue`, and
  `projectValues` take a required trailing `input`, a `Host.LiftInput` that
  says who owns the values: `.partner` for wire data, `.queued` for a message
  a Vat queue owns, and `.borrowed` for a live caller's near-call arguments or
  reply. A caller that lifts a turn's arguments passes
  `Host.LiftInput.ofTurn(turn)`, and one that lifts wire data passes
  `.partner`.
- A refused `.borrowed` lift undoes only its own claims, including the settled
  data an answer reference in it reads. It sends nothing, keeps the session,
  and leaves a redeemed route for the caller's retry, while `.partner` and
  `.queued` still retire every reference through wire GC. Depth
  refusals for `.borrowed` and `.queued` input report `ValueTooDeep`, and a
  `.partner` one stays `NestingTooDeep`.
- A `.borrowed` value refuses an inline handoff give with `UnsupportedValue`
  before the Node sees it, because accepting one cannot be undone. A hosted
  actor that a raw Vat actor calls near with a give now sees that refusal,
  where a partner's or a queued call's give is still accepted.
- `Session.noteHostCapability` returns `!bool` instead of `!void`: whether the
  retain moved out of a held-back resolution hold. A caller that ignored the
  result writes `_ = try`, and `Session.restoreHostCapabilityHeldBack` is the
  inverse.
- A mutation intent counts each argument from depth 0. A stored Loam value
  with a container at depth 64, an empty one included, no longer decodes, and
  a write refuses it. An author whose records hold such a value rewrites each
  one so every container sits at depth 63 or less.
- Use null for the Host’s default `outbound_high_water_bytes`. Construction
  and `setSessionLimits` refuse zero with `InvalidOutboundHighWater`. The C ABI
  reads zero as the default.
- `HostSession.resumeFeed` and `glowcap_host_session_resume_feed` refuse
  with `OutboundBackpressure` (`GLOWCAP_ERR_WOULD_BLOCK`) while a session
  holds input it can dispatch and its queued outbound is at the waterline.
  The input stays held: drain outbound and call again, as each binding's
  pump does.
- A Rooms room name holds no control or text-direction character, as a
  nickname does not. The directory refuses one when a room is opened,
  renamed, or published from another directory, and an IRC bridge refuses a
  channel named with one. A Rooms server whose `rooms.json` holds such a
  name does not start: remove that room's rows from the file, or start from
  a new state directory. The name of a room published from another
  directory is measured as every other room name is, in UTF-16 code units.
- A Rooms nickname or room name may not hold U+061C (the Arabic letter mark),
  which joins the other text-direction characters Rooms refuses. A saved
  archive or session checkpoint that holds such a nickname no longer opens.
  Remove that state directory to start it again.
- A Rooms file name holds no control or text-direction character, as a
  nickname and a room name do not. A direction override draws `photo`
  followed by `gpj.exe` as `photoexe.jpg`. The page refuses such a file
  before it is sent, a room refuses to take one, and a direct message that
  carries one arrives without that file or anything attached after it. A
  saved archive that holds such a file name no longer opens. Remove that
  state directory to start it again.
- A Rooms link preview shows the host its card opens above the title, with
  the port when that is not the scheme's own. The card showed the site name
  the linked page declared, and under a page with no title the host of the
  address that page declared, so a page could name another site on its own
  card. A Rooms server no longer sends the site name, the address, or the
  kind a page declares, and a page that declares only those makes no preview.
  The Rooms page refuses a preview that carries one of them. Update a Rooms
  server and the page that uses it together, or previews fail.
- A Rooms relay reads no WebSocket message larger than 1 MiB, the largest a
  binding's adapter admits. It read one of up to 8 MiB before any byte budget
  counted it. Every glowcap adapter already sends less. A client of another
  implementation sends messages of at most 1 MiB through a Rooms relay.
- A Rooms upload `write` carries at least one byte, and an upload's window
  starts again only when the bytes received reach a multiple of the chunk
  size. Any write started a new window before, an empty one included, so a
  member could hold a reserved upload without sending it. A client of
  another implementation writes whole chunks, or at least one chunk's worth
  of bytes in each window.
- The reply a C behavior callback writes to `out_reply` stays valid and
  unchanged until the library call that ran the callback returns or a
  behavior callback is entered again, whichever comes first. It needed to
  last only across the callback's return. The bundled bindings already keep
  it that long. A C consumer that frees or reuses reply storage as soon as
  its callback returns keeps it for that span. A turn that forwarded its
  answer has its `out_reply` ignored: a value there that would not convert
  does not fail the turn.
- The C ABI drops `GLOWCAP_RESOLUTION_FULFILL`,
  `GLOWCAP_RESOLUTION_BREAK`, and `GLOWCAP_RESOLUTION_HANDOFF`. No function,
  field, or callback took or returned them. C code that names them deletes
  the use.
- `net.Connection.waitReadable`, `waitWritable`, `waitAny`, `waitAnyReadable`,
  and `waitAnyDescriptor` report `poll(2)` failures as `SystemResources`,
  `InvalidWait`, or `Unexpected`. Add those cases to exhaustive Zig switches.
  An invalid descriptor returns `ConnectionLost`. A single-descriptor wait
  uses `net.WaitError`. `net.poll.wait` reports the same errors, waits
  indefinitely for any negative timeout, and keeps the original deadline
  across interrupts.
- A custom `net.MultiplexedResident` reports a connection's carrier phase and
  detail through teardown. `VTable.take_failure` returns
  `?net.carrier_failure.Report`, and `TeardownOutcome.failed` holds a
  `net.carrier_failure.Report`. Return `.{ .chain = chain }` where you
  returned a `foundation.FailureChain`, or `.init(cause)` for a bare cause,
  and read `.chain` where you matched one. `MultiplexedResident.takeFailure`
  returns the report. `MultiplexedResident.connClose` and `Listener.stopListen`
  still return the bare chain, and `connCloseOutcome` and `stopListenOutcome`
  carry the report.
