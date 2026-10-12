---
id: ADR-0090
status: accepted
date: 2026-07-28
tags: [driver, host, api, session, poll, handoff]
decision: "`driver.connect` and `driver.listen` keep their signatures but return sessions backed by a `driver_core.Host` that an owning `driver.HostRuntime` drives with blocking, poll-multiplexed I/O, the native sibling of the pump every binding already runs. A three-party introduction settles as a live capability inside the caller's wait in Zig exactly as it does in every binding, and the two things previously named `Session` collapse into one contract. The direct single-connection tier survives as the borrowing `BlockingSession`, the explicit escape whose caller owns the peer and buffers."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0110, ADR-0112, ADR-0113, ADR-0116, ADR-0184]
---

# ADR-0090 The owning host face

> **Framing amendment (ADR-0110).** The owning face unwraps and emits the outer
> Syrup byte-string envelope at byte-stream connections. Its core-facing frame
> API remains bare.

## Decision

`driver.connect` and `driver.listen` return sessions backed by a
`driver_core.Host` that an owning `driver.HostRuntime` drives with blocking,
poll-multiplexed I/O, the native sibling of the pump every binding runs. A
three-party introduction settles as a live capability inside the caller's wait
in Zig as it does in every binding, and there is one `Session` contract. The
direct single-connection tier is the borrowing `BlockingSession`, the explicit
escape whose caller owns the peer and buffers.

This ADR builds on the sans-io serve core and byte-fed Host
([ADR-0072](ADR-0072-driver-tier-over-c-abi.md)), the loop-fed bridge
([ADR-0076](ADR-0076-loop-fed-host-bridge.md)), the CapTP vocabulary alignment
([ADR-0079](ADR-0079-captp-vocabulary.md)), and the crossed-hello resolution the
host core owns ([ADR-0068](ADR-0068-native-host-tier.md)).

## Problem

In every binding, `Session` is a view onto a multi-session Host: when a reply
introduces a capability on a third machine, the Host dials that machine and the
call settles with a live reference. Native Zig's `glowcap.Session` once owned
one connection and no router, so the same reply handed the caller a `.give`
value that tier could not redeem.

`driver_core.Host` carries identity, crossed hellos, auto-redeem, vows, and both
handoff halves, and every binding drives it byte-fed through `libglowcap_host`.
Native Zig needs a blocking face over that machinery, since the bindings block
on their languages' event loops and native Zig has none.

## Architecture

### Types and ownership

```text
driver.HostRuntime (owning; heap-pinned; src/driver/host_runtime.zig)
├── core: driver_core.Host          sans-io: node, identity, sessions, vows,
│                                   actions — never touches a socket
├── netlayers: []const Netlayer     borrowed; must outlive the Host — later
│                                   redeem dials resolve through this slice,
│                                   so a caller's stack-local array dangles
├── wires: PeerHandle → *Wire           one wire per live session
└── opts: SessionOptions            frame/open admission; wire staging; codec; Budgets

Wire (owning; one per session; private to driver.HostRuntime)
├── conn: net.Connection            the transport byte stream: r/w interfaces,
│                                   TransportHandle, waitReadable, socketHandle
│                                   — its parse machinery (pump/spill) is never
│                                   used; the byte-fed core owns framing
├── read_buf, write_buf: []u8       owned, wire_buffer_bytes-sized; read_buf is the
│                                   transport reader's buffer, write_buf the
│                                   writer's
└── session: *HostSession           the core shell this wire feeds

driver.Session (view; heap-pinned)
├── runtime: *driver.HostRuntime
├── session: *HostSession           which partner this view speaks to
└── owner: Session.Owner            borrowed owns nothing; accepted releases
                                    one session from its Server's shared Host;
                                    private_host tears down the whole Host
                                    bundle built by connect()

driver.Server (owning)
├── runtime: driver.HostRuntime     one identity for every accepted partner —
│                                   which is what makes a give minted for one
│                                   partner verifiable by another
└── listener: net.netlayer.Listener
```

`net.Connection` needed no split: it is already the byte-stream face. Its own
contract exposes `socketHandle` "for a host that multiplexes several
connections with `poll`", `hasBufferedInbound`, and `waitReadable`. The owning
face reads outer-framed bytes off `conn.r`, unwraps each complete body before
feeding the core, and wraps `takeOutbound` frames before writing to `conn.w`.
`pump`/`flush`/`spill` (the parse-into-peer half) stay the blocking
single-connection tier's vocabulary. The one new `net` surface is
`waitAnyReadable`: poll across many connections' fds, honoring buffered
inbound, under one deadline.

### The pump (one fiber, no background thread)

Every blocking wait runs one loop, `pumpUntil(done, budget)`:

1. **Drain the core's action queue** (`core.takeAction`, owned):
   - `flush(peer_handle)`: write that session's `takeOutbound` frames to its
     wire. The frame is freed after the write.
   - `dial(ticket)`: the redeem dial: borrow `core.pendingDial(ticket)`
     (transport, designator, hint), `core.openDialedLocator` to mint the
     session and encode its hello, resolve the netlayer and dial the
     transport, then drive that session's handshake bytes under the
     handshake budget and report `core.exporterDialed(ticket, session)`. Any
     failure reports `core.dialFailed(ticket, reason)` and releases the
     half-open session. The waiting redeem settles broken instead of
     hanging.
   - `need_gift_id(ticket)`: draw 32 bytes at the driver's entropy boundary
     (`drawSessionSecret`'s source) and `core.provideGiftId`.
   - `close(peer_handle)`: write the condemned session's queued abort, then
     close its wire.
   - `settled`/`failed`: completions for vows nobody observed in-process.
     Freed on pop (the Zig face observes through `vowOn`, so these are
     rare).
2. **Check `done`** (the settle flag a `vowOn`/vat listener set while feeding).
   Return if fired.
3. **Wait for readable input** across every live wire (`net.waitAnyReadable`)
   under the remaining budget. On deadline, the wait times out (the same
   `HandshakeTimedOut`/`WaitTimedOut` split the blocking tier already
   speaks).
4. **Read and feed**: for each readable wire, read one chunk into its
   `read_buf` and `core.feedBytes(session, chunk)`. Listeners (settle
   captures, behavior handlers) fire inside this call under the core's
   reentrancy latch. The node pump at its unwind turns replies into gives,
   claims withdraw resolves, and queues the next actions. Loop to 1.

Because step 3 spans all live wires, inbound work on a sibling session (a
deposit arriving while this session waits on a withdraw) is served inside the
same wait. That makes same-host gifter and exporter roles work with no thread,
as the completion loop does with readiness events.

The verb-to-core mapping follows where authority lives. Verbs that carry node
semantics ride the core's vow machinery: `fetch` (a fulfilled capability is
enrolled under a node-unique token before dispatch, ADR-0069, so re-gifting
routes). Raw reference calls still refuse cross-session model arguments because
they own no retain to delay. Owning `Value` calls use ADR-0116's recursive inline
handoff transaction. Session-local
verbs ride the served core the way the borrowing tier does: `spawn`,
`publish`, `on`, `send`/`tell`/`sendToAnswer` on vat refs. Both kinds observe
settlement the same way (a stack-bound capture listener plus `pumpUntil`),
and both are served by the same feed path, so the auto-redeem hooks run no
matter which vocabulary the caller speaks.

### Lifecycle walks

- **connect**: build the private `driver.HostRuntime`, `core.openDialedLocator`
  (registers crossed hellos, encodes the signed hello, refuses a duplicate
  dial), dial the transport into a `Wire`, then `pumpUntil(session open,
  handshake budget)`. Failure at any point unwinds the wire, the session
  shell, and the private host. The caller sees one typed error.
- **accept**: `Server.waitAcceptable` (the stop-friendly poll the CLI's
  Ctrl-C contract needs), then `core.openAccepted` (encodes the responder
  hello naming the listener's dialable designator), `listener.accept` into a
  `Wire`, and `pumpUntil(open, handshake budget)`. Every accepted session
  joins the *same* host: one identity, one live-session directory, shared routing.
- **call with a give inside**: `send` → `pumpUntil(settled, settle budget)`.
  The reply's resolve reaches `hostBeforeServe`, which claims it as a
  withdraw/give. The node queues a `dial` action. The pump answers it inside
  the same wait. The withdrawn capability settles the original capture. The
  caller never sees a `.give`. `Settled.give` remains only on the borrowing
  tier, where "no router" is the caller's explicit choice.
- **Session.deinit**: an accepted view releases its one session
  (`core.releaseSession` breaks its parked vows, fail-closes its sibling
  answers, frees the shell) and closes its wire. A connect-owned view tears
  down the whole private bundle. `Server.close` stops listener admission and
  returns the final runtime teardown outcome when its lease is last. Already
  yielded sessions retain their leases and remain usable. Implicit destruction
  sends an otherwise callerless teardown failure to the process-installed
  `SessionOptions.unhandled_failure` observer.

### Boundaries

- **fd-backed transports only.** Multiplexed blocking waits need readiness,
  so a wire whose transport reports no pollable fd (`socketHandle() == null`:
  inproc, iroh's userspace stream) is refused at open with a
  typed error naming `completion.Loop` as the tier that serves it. This is
  the boundary `BlockingSession` documents for budgets.
- **One thread drives one `driver.HostRuntime`**. This is inherited from the core's
  unsynchronized contract and its debug owner assert.
- Redeem connect inherits its provider. Driver providers begin connects
  nonblocking. A native Zig stream netlayer may instead declare the blocking
  arm of its one tagged dial operation, whose connect syscall is outside the
  handshake budget. The handshake itself remains bounded either way.
- No 500k claim: the owning face is the application tier. Its per-session
  cost (shell + peer + two wire buffers) and its per-host cost (one
  node) are named in the memory rule. The completion loop remains the scale
  path and the bridge is untouched.

## Scope (what this does not decide)

The borrowing C ABI is unchanged. ADR-0112 projects this owning face through the
separate driver ABI without moving transport execution into the borrowing host
family. The borrowing tier keeps its whole surface. This face adds no CapTP
semantics: every behavior it exposes is the core's, held by the byte-fed host
tests and the binding interop steps.

## Alternatives Considered

- **Rename the direct tier (`DirectSession`) and add `driver.HostRuntime` beside
  it.** Rejected: two front doors survive.
- **Wrap `Bridge` + `completion.Loop` in a background thread and park blocking
  verbs on completions.** Rejected: a hidden thread is a hidden runtime and
  imports cross-thread synchronization into a single-fiber tier.
- **Teach `BlockingSession` a `Node` so it can redeem.** Rejected: it rebuilds the
  Host's identity, crossed-hello, and router authority at a second site, the
  duplication ADR-0072 exists to prevent.
- **Split a `ByteStream` type out of `net.Connection`.** Rejected: the
  connection already states the multiplexing contract this face needs.

## Consequences

- `src/driver/host_runtime.zig` holds `driver.HostRuntime`, `Wire`, the pump,
  and the `Session`/`Server` views. `net.waitAnyReadable` is the multi-wire
  wait.
- `driver/session.zig`'s owning tier is implemented over the host face, so
  `cli/`, the C tcp session, the examples, and the driver loopback tests use it
  unchanged. Inproc loopback tests run over TCP loopback because the face's
  fd-backed boundary refuses inproc.
- Evidence: the driver loopback and budget tests keep passing. New tests pin
  the front-door handoff on TCP and on keyed-tcp (the latter proving the
  give's `direct-addresses` hint survives the redeem dial), the owning
  pump's handshake budgets on both the connect and accept sides (silent
  partner, expired budget, and the accept-failure unwind under the testing
  allocator), and, implicitly but bindingly, sibling-session service
  during a wait, which hangs the handoff tests if it breaks. Teardown
  leak-freedom rides the testing allocator throughout.
- Docs in the same change: `docs/architecture.md`'s four-names table,
  `bindings/README.md`'s native-Zig paragraph, `docs/shipped.md`,
  `docs/boundaries.md` (the fd-backed boundary), the memory rule's
  allocation entries, and example chapter 02's framing (the loop remains
  the scale path).
