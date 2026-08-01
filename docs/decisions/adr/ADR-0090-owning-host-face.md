# ADR-0090: The Owning Host Face

**Status:** Decided (built with this ADR; the owning tier rides it)
**Date:** 2026-07-28
**Decision:** `driver.connect` and `driver.listen` keep their signatures but
return sessions backed by a `driver_core.Host` that a new owning `driver.PollHost`
drives with blocking, poll-multiplexed I/O — the native sibling of the pump
every binding already runs. A three-party introduction settles as a live
capability inside the caller's wait in Zig exactly as it does in every
binding, and the two things previously named `Session` collapse into one
contract. The direct single-connection tier survives as the borrowing
`BlockingSession`, the explicit escape whose caller owns the peer and buffers.

This ADR builds on the sans-io serve core and byte-fed Host (ADR-0072), the
loop-fed bridge (ADR-0076), the CapTP vocabulary alignment (ADR-0079), and the
crossed-hello resolution the host core owns (ADR-0068).

---

## Problem

Two different types answered to the name `Session`, and the weaker one owned
the front door. In every binding, `Session` is a view onto a multi-session
Host: when a reply introduces a capability on a third machine, the Host dials
that machine and the call settles with a live reference. Native Zig's
`pancake.Session` owned exactly one connection and no router, so the same
reply handed the caller a `.give` value that tier could not redeem.

The core that fixes this exists and is proven five times over:
`driver_core.Host` carries identity, crossed hellos, auto-redeem, vows, and
both handoff halves, and every binding drives it byte-fed through
`libpancake_host`. What Zig lacked was a *blocking face* over that machinery:
the bindings block on their languages' event loops, and native Zig has none.

## Architecture

### Types and ownership

```text
driver.Host (owning; heap-pinned; src/driver/host.zig)
├── core: driver_core.Host          sans-io: node, identity, sessions, vows,
│                                   actions — never touches a socket
├── netlayers: []const Netlayer     borrowed; must outlive the Host — later
│                                   redeem dials resolve through this slice,
│                                   so a caller's stack-local array dangles
├── wires: PeerId → *Wire           one wire per live session
└── opts: SessionOptions            frame_cap → limits; codec; both Budgets

Wire (owning; one per session; private to driver.Host)
├── conn: net.Connection            the transport byte stream: r/w interfaces,
│                                   TransportHandle, waitReadable, socketHandle
│                                   — its parse machinery (pump/spill) is never
│                                   used; the byte-fed core owns framing
├── read_buf, write_buf: []u8       owned, frame_cap-sized; read_buf is the
│                                   transport reader's buffer, write_buf the
│                                   writer's
└── session: *HostSession           the core shell this wire feeds

driver.Session (view; heap-pinned)
├── host: *driver.PollHost
├── session: *HostSession           which partner this view speaks to
└── owns_host: bool                 connect() builds a single-session Host
                                    underneath and hands back its one view, so
                                    deinit tears the whole bundle down;
                                    Server.accept views borrow the Server's
                                    Host and deinit releases one session only

driver.Server (owning)
├── host: driver.Host               one identity for every accepted partner —
│                                   which is what makes a give minted for one
│                                   partner verifiable by another
└── listener: net.netlayer.Listener
```

`net.Connection` needed no split: it is already the byte-stream face — its own
contract exposes `socketHandle` "for a host that multiplexes several
connections with `poll`", `hasBufferedInbound`, and `waitReadable`. The owning
face reads raw bytes off `conn.r` and writes `takeOutbound` frames to
`conn.w`; `pump`/`flush`/`spill` (the parse-into-peer half) stay the blocking
single-connection tier's vocabulary. The one new `net` surface is
`waitAnyReadable`: poll across many connections' fds, honoring buffered
inbound, under one deadline.

### The pump (one fiber, no background anything)

Every blocking wait runs one loop, `pumpUntil(done, budget)`:

1. **Drain the core's action queue** (`core.takeAction`, owned):
   - `flush(peer_id)` — write that session's `takeOutbound` frames to its
     wire; the frame is freed after the write.
   - `dial(ticket)` — the redeem dial: borrow `core.pendingDial(ticket)`
     (transport, designator, hint), `core.openDialedLocator` to mint the
     session and encode its hello, resolve the netlayer and dial the
     transport, then drive that session's handshake bytes under the
     handshake budget and report `core.exporterDialed(ticket, session)`. Any
     failure reports `core.dialFailed(ticket, reason)` and releases the
     half-open session; the waiting redeem settles broken instead of
     hanging.
   - `need_gift_id(ticket)` — draw 32 bytes at the driver's entropy boundary
     (`drawSessionSecret`'s source) and `core.provideGiftId`.
   - `close(peer_id)` — write the condemned session's queued abort, then
     close its wire.
   - `settled`/`failed` — completions for vows nobody observed in-process;
     freed on pop (the Zig face observes through `vowOn`, so these are
     rare).
2. **Check `done`** (the settle flag a `vowOn`/vat listener set while feeding)
   — return if fired.
3. **Wait for readable input** across every live wire (`net.waitAnyReadable`)
   under the remaining budget; on deadline, the wait times out (the same
   `HandshakeTimedOut`/`WaitTimedOut` split the blocking tier already
   speaks).
4. **Read and feed**: for each readable wire, read one chunk into its
   `read_buf` and `core.feedBytes(session, chunk)`. Listeners (settle
   captures, behavior handlers) fire inside this call under the core's
   reentrancy latch; the node pump at its unwind turns replies into gives,
   claims withdraw resolves, and queues the next actions. Loop to 1.

Because step 3 spans *all* live wires, inbound work on a sibling session — a
deposit arriving while this session waits on a withdraw — is served inside
the same wait. That is what makes same-host gifter and exporter roles work
with no thread, and it is the single-fiber analog of what the completion
loop does with readiness events.

The verb-to-core mapping follows where authority lives. Verbs that carry node
semantics ride the core's vow machinery: `fetch` (a fulfilled capability is
enrolled under a node-unique token before dispatch, ADR-0069, so re-gifting
routes), `fetchReference`/`callReference`/`sendReference` (token targets route
through `core.routeSend`, with `ForeignArgument` refused whole). Session-local
verbs ride the served core the way the borrowing tier does: `spawn`,
`publish`, `on`, `send`/`tell`/`sendToAnswer` on vat refs. Both kinds observe
settlement the same way — a stack-bound capture listener plus `pumpUntil` —
and both are served by the same feed path, so the auto-redeem hooks run no
matter which vocabulary the caller speaks.

### Lifecycle walks

- **connect**: build the private `driver.PollHost`, `core.openDialedLocator`
  (registers crossed hellos, encodes the signed hello, refuses a duplicate
  dial), dial the transport into a `Wire`, then `pumpUntil(session open,
  handshake budget)`. Failure at any point unwinds the wire, the session
  shell, and the private host; the caller sees one typed error.
- **accept**: `Server.waitAcceptable` (the stop-friendly poll the CLI's
  Ctrl-C contract needs), then `core.openAccepted` (encodes the responder
  hello naming the listener's dialable designator), `listener.accept` into a
  `Wire`, and `pumpUntil(open, handshake budget)`. Every accepted session
  joins the *same* host: one identity, one live-session directory, shared routing.
- **call with a give inside**: `send` → `pumpUntil(settled, settle budget)`.
  The reply's resolve reaches `hostBeforeServe`, which claims it as a
  withdraw/give; the node queues a `dial` action; the pump answers it inside
  the same wait; the withdrawn capability settles the original capture. The
  caller never sees a `.give` — `Settled.give` remains only on the borrowing
  tier, where "no router" is the caller's explicit choice.
- **Session.deinit**: an accepted view releases its one session
  (`core.releaseSession` breaks its parked vows, fail-closes its sibling
  answers, frees the shell) and closes its wire. A connect-owned view tears
  down the whole private bundle. `Server.close` sweeps every remaining
  session, then the listener, then the host.

### Boundaries (hard, not advisory)

- **fd-backed transports only.** Multiplexed blocking waits need readiness,
  so a wire whose transport reports no pollable fd (`socketHandle() == null`
  — inproc by design, iroh's userspace stream) is refused at open with a
  typed error naming `completion.Loop` as the tier that serves it. This is
  the boundary `BlockingSession` documents for budgets, made structural.
- **One thread drives one `driver.PollHost`** — inherited from the core's
  unsynchronized contract and its debug owner assert.
- The redeem dial's TCP connect syscall is not budget-bounded (the same
  posture `connectVia` has always had); the handshake after it is.
- No 500k claim: the owning face is the application tier. Its per-session
  cost — shell + peer + two frame_cap buffers — and its per-host cost — one
  node — are named in the memory rule; the completion loop remains the scale
  path and the bridge is untouched.

## Scope (what this does not decide)

The C ABI is untouched (bindings already drive the core directly). The
borrowing tier keeps its whole surface. No new CapTP semantics exist
anywhere: every behavior this face exposes is the core's, already held by
the byte-fed host tests and the binding interop steps.

## Alternatives Considered

- **Rename the direct tier (`DirectSession`) and add `driver.PollHost` beside
  it.** Rejected: two front doors survive, and the confusion halves instead
  of dying.
- **Wrap `Bridge` + `completion.Loop` in a background thread and park
  blocking verbs on completions.** Rejected: a hidden thread is a hidden
  runtime, and it imports cross-thread synchronization into the tier whose
  point is single-fiber clarity.
- **Teach `BlockingSession` a `Node` so it can redeem.** Rejected: rebuilds
  the Host's identity, crossed-hello, and router authority piecemeal at a
  second site — the duplication ADR-0072 exists to prevent.
- **Split a `ByteStream` type out of `net.Connection`.** Rejected on
  reading the code: the connection already states the multiplexing contract
  this face needs; a split would relocate three accessors to rename a type.

## Consequences

- New: `src/driver/host.zig` (`driver.PollHost`, `Wire`, the pump, the
  `Session`/`Server` views); `net.waitAnyReadable`.
- Reworked: `driver/session.zig`'s owning tier is reimplemented over the
  host face with signatures unchanged, so `cli/`, the C tcp session, the
  examples, and the driver loopback tests migrate by recompiling — except a
  test that rode the owning tier over inproc, which moved to TCP loopback
  because the face's own fd-backed boundary refuses inproc.
- Evidence: the driver loopback and budget tests keep passing; new tests pin
  the front-door handoff on TCP and on keyed-tcp (the latter proving the
  give's `direct-addresses` hint survives the redeem dial), the owning
  pump's handshake budgets on both the connect and accept sides (silent
  partner, expired budget, and the accept-failure unwind under the testing
  allocator), and — implicitly but bindingly — sibling-session service
  during a wait, which hangs the handoff tests if it breaks. Teardown
  leak-freedom rides the testing allocator throughout.
- Docs in the same change: `docs/architecture.md`'s four-names table,
  `bindings/README.md`'s native-Zig paragraph, `docs/shipped.md`,
  `docs/boundaries.md` (the fd-backed boundary), the memory rule's
  allocation entries, and example chapter 02's framing (the loop remains
  the scale path).
