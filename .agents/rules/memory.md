---
description: "Zig pancake memory and frame ownership: owned transfer, bounded borrow, explicit test-only copies."
globs: src/foundation/**/*.zig, src/codec/**/*.zig, src/engine/**/*.zig, src/c_abi/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h
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
  alignment used to free it — decoupled from `shape`, so a byte frame may be
  over-aligned and still frees with its true allocation metadata.
- `Frame.view` borrows without allocation.
- `Peer.send(Message)` takes ownership and moves the message into the outbound
  queue — the canonical, copy-free spine.
- `Peer.sendCopying(Message)` names the one boundary copy over `send`, for
  callers that hold borrowed or static message data they keep owning.
- `engine.pipeline.decomposeOutboundDeliver` splits a multi-hop pipelined
  deliver into single-hop links by *moving* each path step's payload into its
  own message (and freeing only the emptied `path.ops` backing slice) — a spine
  repartition, not a copy. The one allocation is the `[]Message` chain container.
- `Peer.feedInbound(Frame)` transfers ownership for queued dispatch.
- `Peer.recvBorrowed(FrameView)` dispatches during the call and retains no wire
  borrow.
- `Peer.emitAbortForError` (inbound failure → outbound `op:abort`) encodes a
  fresh abort `Frame` straight onto `outbound`, bypassing `recordSend` (aborts
  are always admitted and the session is being torn down). The abort's diagnostic
  is a static `[]const u8` borrowed by encode — no message clone. Best-effort: an
  encode/append failure is swallowed so the original dispatch error is never
  masked, but the session still closes when the projection (`abort_projection`)
  requires it.
- `MemoryEndpoint.writeFrameOwned(Frame)` transfers ownership.

Copy helpers belong in `test/support`, not production modules.

## Load-bearing allocations

Each allocation / copy below was scrutinized against *"a copy is a design event:
forbid it, name it, or measure it"* and is **required** — the value sanctions a
named copy, and these are named here. Do not "optimize" one away without
re-deriving the contract that forces it.

- **Outbound boundary copy — `Peer.sendCopying` → `model.cloneMessage`.** The
  outbound queue *owns* messages until `step` encodes them (deferred encode,
  architecture Invariant 14). The handshake / handoff drivers and the conformance
  harness feed *borrowed*, fixed-array, or static input (a `KeyPair`'s `[32]u8`,
  a caller-owned `HandoffGive`, a literal abort reason). Owning queue + borrowed
  input ⇒ exactly one copy. The spine moves through `Peer.send`; this is the one
  named boundary copy, and deleting it only relocates the same dupes into each
  driver (worse: scattered, duplicating `clonePeerLocator`).
- **Owned inbound frame — `ownedFrameFromView` (`Peer.recvBorrowed`).** A borrowed
  `FrameView` is transient; a surfaced event must outlive it, so the bytes are
  copied once into an owned `Frame`. Word-shaped frames need 8-byte-aligned
  storage, hence `alignedAlloc` + `@memcpy` rather than `dupe`. The owned-frame
  and zero-copy borrow paths split exactly here. This is the *only* allocation a
  steady-state inbound deliver to a live export costs — the irreducible
  wire-path floor asserted by `test/engine/alloc_budget_test.zig`.
- **Borrowed-validate / owned-on-retain inbound path — `Session.recordRecvView`.**
  The session is codec-neutral but `model.view.Body` is a codec-neutral *borrowed*
  projection over the frame, so the common inbound kinds (deliver / resolve /
  listen / start-session / abort) validate and apply session authority directly
  from it — zero per-turn materialization. An owned `Message` is materialized
  only on the two paths that *retain*: a pipelined deliver queued on its answer
  (`Peer.maybeEnqueuePipelinedCall`), and the rare sub-structure-heavy kinds
  (`gc_*`, `handoff`, `get`/`index`) that fall back to one owned validate/apply.
  That owned-fallback copy is *turn-scratch*, not session-lived: it feeds the
  shared owned validate/apply and dies when the turn ends, so it is materialized
  into the session's **`recv_scratch`** bump arena and reclaimed with one
  `reset(.retain_capacity)` at the end of every `recordRecvView` — the
  per-message dupe-then-`freeMessage` choreography collapses to a bump-and-reset,
  and capacity amortizes across turns. Apply dupes anything session-lived onto
  the gpa, so resetting the scratch can never dangle a table row. The argument
  walk that validates and the install walk are depth-bounded
  (`SessionLimits.max_nesting_depth`) so an attacker-nested arg tree fails loud
  (`NestingTooDeep` → `resource_exhausted` abort) instead of overflowing the
  native stack.
- **Crypto fixed-width materialization — `crypto.PeerKey.fromSlice`,
  `crypto.Signature.fromParts`.** `std.crypto` Ed25519 operates on fixed-size
  arrays (`[32]u8` / `[64]u8`) while the wire exposes `[]const u8`. Materializing
  the array from a borrowed slice is an inherent, bounded copy at the verification
  boundary — `std.crypto` offers no allocator pattern to avoid it.
- **Authoritative session state — `model.clonePeerLocator`, plus the per-session
  byte key arena.** Session tables are the source of truth (Invariant 5) and
  outlive any borrowed frame, so an owned `op:start-session` locator is duped into
  session-owned storage. The byte-keyed tables are position/key-keyed hash maps
  (no linear `std.mem.eql` scans): exports / imports / answers are O(1)
  position-keyed `SlotTable` / `AnswerTable`; `gifts`, `handoff_counts`, and the
  `bootstrap` registry are O(1) `StringHashMap`s whose key (and gift recipient-key)
  bytes live in one per-session **`key_arena`**, freed wholesale at teardown — the
  *monotonic* tables never remove a row, so a bump arena is the right owner.
  Deliberately excluded from the arena: the FIFO-evicting `sturdyref_cache` and
  the individually-removed `pending_enlivens` / imported-promise hosts keep their
  swissnum / host bytes on the gpa with precise per-row frees, because a bump
  arena cannot reclaim an evicted or removed row and would leak under churn.
- **Listener fan-out — one synthesized fire per listener.** When a promise with
  N listeners resolves, [`engine.pipeline.synthesizeListenerFire`] builds each
  listener its own owned `op:deliver` carrying the resolution payload (one stored
  resolution → N independently-freed delivers). Irreducible without refcounted
  shared payloads, which would trade an explicit copy for hidden shared
  ownership. The drain spine otherwise *moves*: drained entries flow into a
  [`engine.pipeline.ListenerDrainAction`] and then onto `pending_send` /
  the listener table without copying.
- **Partial-listener re-anchor — one `model.cloneReference` per partial fire.**
  The single named clone in the listener drain: a `wants_partial` listener that
  resolves to another promise must both fire now (with the partial promise) and
  stay anchored on the next answer, so [`engine.pipeline.classifyListenerDrain`]
  duplicates the listener target. V1.0-only by construction (PreSpec never sets
  `wants_partial`); every other resolution shape moves the target into the fire.
- **Boxed handoff argument — `model.owned.cloneHandoffBoxed` (one alloc per
  `desc:handoff-*` *argument*).** The owned `Argument.handoff` arm is `*Handoff`,
  not inline: a handoff payload is ~160 bytes and would otherwise set the size of
  *every* `Argument`, so an ordinary integer arg in a deliver list would pay for
  the handoff arm it never uses (`Argument` 168 → 88 bytes, `Resolution` 176 →
  96; measured by `bench/frame_view_bench.zig`). The cost is one `create(Handoff)`
  only when a handoff actually appears as an argument — rare (three-party only) —
  freed once in `freeArgument`. The borrowed `model.view.Argument` keeps its
  handoff inline; it borrows wire bytes and never allocates, so the box lives only
  on the owned/retain side.
- **Local-delivery frame synthesis — `Peer.deliverDrainedCallLocally`.** When a
  pipelined call's answer resolves to a *local* export, the drained call is
  delivered to that export by encoding the re-targeted `op:deliver` into a fresh
  `Frame` and surfacing it as an event — the same shape a directly-received
  deliver carries, so the application dispatches it uniformly. The queued message
  itself *moves* into the rewrite; the one allocation is the synthesized frame,
  which the frame-based event model requires (a borrowed frame can't carry a
  message that never arrived on the wire). Bounded by `max_local_deliveries`.
- **Relayed-resolution forwarding — borrow-then-move (ADR-0009).**
  `Peer.applyRelayedResolution` fires the handoff-imported promise's listeners by
  *borrowing* the forwarded resolution (each fire goes through the listener
  fan-out above, which clones the payload per listener), then *moves* the same
  resolution into the import's stored slot via `Session.recordRelayedResolution`
  — no extra clone of the resolution itself. A late `op:listen` fires from that
  stored resolution by *borrowing* it again (`Peer.maybeFireLateImportedListener`
  reads `*const Resolution`), leaving it in place for further late listeners; the
  stored resolution is freed once (on overwrite or on import GC co-eviction).
- **Sturdyref enliven dedup — one swissnum dupe per cache / in-flight row
  (ADR-0012).** `Session.cacheSturdyrefEnlivenment` and `notePendingEnliven` each
  `dupe` the swiss-number into a session-owned row; the resolved cache stores only
  the `(import_id, kind)` POD alongside it, never a clone of the enlivened
  reference. `engine.sturdyref.recordEnlivenment` *moves* the fulfilled
  `Reference.far` out to the caller (POD `FarRef`, no heap) and copies just its
  `import_id` + `kind` into the cache. The cache is non-load-bearing: an overflow
  evicts the oldest row (freeing its swissnum) and a failed insert is swallowed —
  a miss costs one extra bootstrap-fetch round-trip, not correctness. Each owned
  swissnum is freed once on overwrite-evict, `finishPendingEnliven`, or
  `Session.deinit`.

### Named Deferred Costs

- *(empty.)*

## Allocator Discipline

- The owner that allocates releases.
- Store enough metadata to free correctly; word storage must be freed with word
  alignment.
- Never hide allocation behind a neutral API name.
- Do not add `unsafe` as an optimization shortcut. Escalate first.

If a caller cannot tell whether an API transfers, borrows, or copies, the API is
wrong.
