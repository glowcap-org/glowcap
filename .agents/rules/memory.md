---
description: "Zig glowcap memory and frame ownership: owned transfer, bounded borrow, explicit test-only copies."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h
---

# glowcap — Memory and Frame Ownership

## A copy is a design event

Every allocation or copy on the wire path is **forbidden, named, or measured**,
and forbidding is the default verdict. Naming one is a decision you have to
earn: re-derive it against the _full_ option set, not the binary the copy first
presents. A copy is not "copy versus retain the whole source" when one durable
owner can hold the value; a shim is not "shim versus break the world" when the
world is yours to change ([prerelease](prerelease.md) — there is no migration
to pay).

Cross-surface consistency is part of that derivation: a negligible cost off
the wire path, paid so sibling fronts keep one contract, earns its name more
easily than a micro-saving earns an asymmetry.

**Deleting a copy is a claim about cost, so measure it.** The allocation
budgets count allocations, not work, so a change can delete one copy, add a
growth realloc, and still pass every gate green. A reservation that lands just
under a common message size is the usual way this happens, and it is asymmetric:
reserving spare capacity is nearly free where falling one unit short is not. Run
the `bench/` step covering the path against the pre-change tree before claiming
the win.

**Do not "optimize" away a ledger entry without re-deriving its contract**, and
do not add one without earning a place beside them.

If a caller cannot tell whether an API transfers, borrows, or copies, the API is
wrong.

## Frame contract

- `Frame` owns wire bytes; `FrameView` borrows them for a bounded call.
- `FrameShape.byte` means ordinary byte storage.
- `FrameShape.word` means word-aligned storage: pointer aligned to 8, byte
  length divisible by 8.
- Allocation alignment is tracked separately from `shape`, so a byte frame may
  be over-aligned and still free with its true allocation metadata.

## Ownership verbs

- `Frame.initOwned` adopts storage without copying. `Frame.view` borrows without
  allocating.
- `Peer.send(Message)` takes ownership and moves the message into the outbound
  queue. This is the canonical, copy-free path.
- `Peer.sendCopying(Message)` names the one boundary copy over `send`, for
  callers holding borrowed or static message data they keep owning.
- `Peer.feedOwned(Frame)` transfers ownership for queued dispatch, consuming the
  frame on every outcome. `Peer.recvBorrowed(FrameView)` dispatches during the
  call and retains no wire borrow.
- Promise-chain drain allocates no chain container: one bounded,
  allocation-free exact-incarnation walk finds the terminal or pending target,
  then each queued call moves directly to that target or its terminal
  consequence.
- `Peer.emitAbortForError` handles an inbound refusal, including the inbound
  dispatch arm of `step`, by committing a fresh outbound `op:abort` through
  `Peer.commitAbortOutbound`, bypassing `recordSend`, because a session being
  refused always admits its abort. Deferred local work and outbound encoding
  propagate pressure without calling it: the same `OutboundBackpressure` name
  means a partner-owned cap only at the inbound boundary. The diagnostic is a
  static `[]const u8` borrowed by encode, so there is no message clone. The path
  retains an encode or append failure as `AbortInfo.abort_delivery_error` while
  returning the original dispatch error, and the session still closes when the
  projection requires it, even with no queued frame. Host admission reserves
  the resulting flush notification, so publishing that embedder effect is
  infallible after the session exists. Cleanup consequences retain their first
  name and bounded count in `AbortInfo.secondary_error`; its saturation test
  and the `Peer` size gate keep that diagnosis inside already-paid padding.
- Test-support copy helpers (`test/support/frame.zig`, for example
  `copyFromBorrowed`) materialize borrowed wire bytes for assertions. **Copy
  helpers belong in `test/support`, never in a production module.**

## Allocator discipline

- The owner that allocates releases. Store enough metadata to free correctly;
  word storage must be freed with word alignment.
- Never hide allocation behind a neutral API name.
- Do not add `unsafe` as an optimization shortcut. Escalate first.
- A map removal whose key presence is an established invariant asserts it:
  `std.debug.assert(map.remove(k))` still runs the remove in release and only
  adds the check in safe builds. Only a genuinely idempotent ensure-absent
  removal discards the bool, and then it carries an inline `// idempotent:` or
  `// tolerant:` justification. `source-check` holds this for every
  `_ = <map>.remove(` / `.fetchRemove(` / `.swapRemove(` in `src/`.

## Footprint budgets that bite

The 500k-connection destination is gated by the build (ADR-0045), so **a field
added to session state is a withdrawal from it**. When a gate below trips, weigh
the bytes and raise the budget deliberately, in the constant and in
`docs/ladder.md` step 2 together. Never route around the check. Every number
below is a runtime-safety measurement (Debug and ReleaseSafe): each embedded
std list or map header carries a one-word `pointer_stability` lock there that
ReleaseFast and ReleaseSmall drop, so a fast build measures a word less per
container and the ceilings absorb it.

| Gate | Holds |
| --- | --- |
| `@sizeOf(Peer)` comptime (`peer_session_struct_budget_bytes`, 1176) | one session's struct |
| `test/engine/footprint_budget_test.zig` | a warmed session's core state at or under 2 KiB |
| `@sizeOf(Conn) - @sizeOf(engine.Peer)` comptime in `src/net/completion/loop/state.zig` | the loop wrapper's own bookkeeping at exactly `conn_slot_overhead_bytes` (144). An equality, so a field added to `Conn` fails the build rather than spending headroom nobody is watching |
| `CompletionBackend.connection_state_bytes` / `secure_connection_state_bytes` in `test/net/keyed_relay_completion*_test.zig` | the completion-backed keyed-relay adapter state at exactly 272 bytes for a clear leg; WSS alone adds a sparse 37,216-byte TLS state including its two fixed 18 KiB record windows. Clear legs pay none of it. Mask entropy belongs to the single-owner backend RNG, not a 520-byte CSPRNG copied into every connection |
| `CompletionBackend.connection_state_bytes` in `test/net/iroh_resident_internal_test.zig` | one iroh loop connection's adapter row at exactly 64 bytes: the sidecar handle beside the hinted try-I/O seats, hints, and terminal cause every multiplexed sidecar backend shares (`net.completion.HintedTryIo`) |
| `Backend.connection_state_bytes` in `test/net/webrtc_internal_test.zig` | one open WebRTC DataChannel's adapter row at exactly 104 bytes: the 48-byte sidecar peer beside the same shared seats |
| `@sizeOf(HostSession)` comptime in `src/driver/core/host/session.zig` | the byte-fed host shell. The Host session ceiling is 528 bytes (ADR-0107's sealed-channel pointer is the last eight); narrower targets may be smaller. The Host owns one shared Vat, so the Vat (eight of its bytes the local ingress's runnable-ring back pointer, bought so a budgeted drive unlinks one ingress in O(1)) is charged once per Host rather than per session, inside the `@sizeOf(Host)` pin in `test/driver/core_host/admission_test.zig`, and a `Peer` lives behind a pointer |
| `test/actors/vat_footprint_budget_test.zig` | a burst-then-quiescent Vat back under the arena and one-spare bounds |
| `test/engine/deliver_set_scratch_budget_test.zig` | a big-set frame's recv scratch under its bound |

Retained capacity is bounded per owner, so a burst cannot pin its peak for the
connection's life:

- The engine's four peer queues each bound retained backing at
  `steady_retain_bytes: usize = 4096` (`src/ocapn/engine/peer/queue.zig`),
  freeing burst capacity at the drain for the named price of one growth
  re-allocation when the next burst begins.
- `Session.recv_scratch` keeps only `steady_recv_scratch_bytes = 384`
  (`src/ocapn/session/mod.zig`, beside the field). It is far smaller than the
  queues' bound because the session answers to the 2 KiB core-state budget and
  its arena must leave room for the tables beside it, while one admissible frame
  can grow the arena to several times `max_frame_bytes` in owned `Argument`s.
- The actor layer holds the same posture at Vat scale
  (`src/actors/vat/mod.zig`): `steady_turn_arena_bytes` and
  `steady_settle_arena_bytes` bound the two long-lived arenas at 4096,
  `steady_spare_arena_bytes` (4096) bounds the one Vat-wide spare queue chunk,
  and `steady_list_bytes` (4096) bounds the `moved_replies` list and sets the
  fixed queue-row target. An empty ingress retains no chunk at all, and the
  allocation budget proves a warmed local queue batch performs zero
  general-purpose allocations.

## The ledger

Every allocation and copy that survived the derivation above has one entry in
the [memory ledger](memory-ledger.md), which `source-check` holds to a
declaration under `src/`. Add an entry there when a cost earns its name, and
delete one only after re-deriving its contract.
