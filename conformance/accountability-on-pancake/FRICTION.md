# Friction log — building the first real app on pancake

Every place pancake was harder to build on than it should have been, what it cost,
and what changed or is now queued. This is the honest measure of whether pancake is
amazing to build on yet. Newest insight first within each section.

## Fixed in this change

### 1. The Goblins V1.0 wire could not carry a *broken* promise (codec, fixed)

**Symptom.** The whole point of accountability is refusing a caller you cannot
attest. The first time the host refused, turning an unattested signature into a
broken promise, the host's session aborted the conversation with `ProtocolAbort`
instead of delivering the refusal.

**Root cause.** Under the canonical Goblins V1.0 profile a resolution travels as a
resolver-callback `op:deliver` whose args are `['fulfill payload]` or
`['break <error>]`. The Syrup codec could *decode* an `<error …>` record in argument
position, where `readNeutralArgument` produces an `.@"error"`, but `writeArgument` had no matching
arm, so encoding the `break` args failed with `UnsupportedArgument`. A clean
encode/decode asymmetry: pancake could read a broken-promise argument it could not
write.

**Fix.** Added the symmetric `.@"error"` arm to `writeArgument` (it reuses the
existing `writeError`), plus a round-trip test in `test/codec/syrup_test.zig`. The
switch is now exhaustive over `model.Argument`, so a future variant fails the build
rather than silently hitting an `else`. This is a bug fix restoring symmetry, not a
new affordance — it stays inside the codec boundary.

**Why it mattered.** The refusal path is the security-relevant half of the feature.
Without this, pancake could express "yes" over V1.0 but not "no, I won't account for
you" — exactly the message a capability-secure system most needs to send.

## Queued (priority order)

### 2. A refused frame's cause is hard to see through the adapter

`net_adapter.Connection.pump` flattens every session-authority refusal to
`PumpError.ProtocolAbort`, dropping the typed cause. When the broken-promise encode
above failed, the only signal a consumer got was `ProtocolAbort` with an empty
reason. The typed cause was only recoverable by driving `peer.step()` directly,
outside the connection. The host *does* project an `op:abort` carrying the typed
kind, but on a concurrent-fiber socket the close raced the abort frame away before
the caller could read it.

Queued: a way to read the last projected abort's domain/kind off the peer (or carry
it on the `PumpError`) so a consumer can diagnose a refusal without bypassing the
adapter. Cost paid this round: most of the debugging time.

### 3. No vat-level "publish as bootstrap, fetch by name"

The app agrees on an export id (`AFFORDANCE_EXPORT = 5`) on both sides out of band.
That is fine for a two-peer worked example, but a stranger does not know your export
ids — they `fetch` a capability by swissnum from your bootstrap object. The engine
has the bootstrap-fetch responder (`registerBootstrapCap`, proven in `tcp_test`),
but `actors.Vat` has no helper that says "publish this actor behind a swissnum" and
"fetch the actor behind this swissnum." A first-class consumer wants that on the vat.

Queued: a `Vat.publishBootstrap(actor, swissnum)` / `Vat.fetch(swissnum)` pair so the
capability-acquisition handshake is ergonomic, not hand-wired.

## Things that went *right* (DX worth keeping)

- **The V1.0 reply machinery is automatic on the send side.** A far eventual-send
  that wants a reply gets a synthesized resolver export and `resolve_me_desc`
  injected by `prepareOutboundWireMessage`; the matching inbound resolver-callback is
  translated back to a semantic resolution. The app's `vat.send` followed by
  `vat.on(promise)` reads like a normal promise even though the wire is doing
  resolver-callback translation underneath. That is the right division of labor.
- **`actors.Vat` over a borrowed `Peer` is the right grain** for a host: `spawn` +
  `publish` + `serve` mapped cleanly onto "host an Affordance," and `send` + `on`
  mapped cleanly onto "invoke and await."
- **The portable core stayed honest.** No application vocabulary leaked down; the
  one core change was a codec symmetry fix, gated by a test.

### 4. The C ABI and the native Zig path disagree on session state

The C ABI creates peers in `open` state (no handshake); the native Zig
`initNegotiating` starts in `negotiating` state with the Goblins V1.0 wire profile
and expects an `op:start-session` exchange. A host that wants to serve both native
Zig callers and foreign C ABI callers cannot use one code path — the standalone host
had to switch from `initNegotiating` to `init` to be reachable from Deno. This
means the cross-seam host runs without the V1.0 profile (no resolver-callback
translation), and the native-only demo runs with it. The gap is real: a single host
that accepts both Zig-native and C ABI connections would need either negotiation on
the wire (the handshake) or a way to detect which path the caller is on. For now,
two separate entry points (main.zig for native-only, host.zig for cross-language)
paper over it.

Queued: consider making the C ABI path also support the negotiating-to-open handshake,
or providing an `initOpen` variant that native Zig callers can use when they do not
need the V1.0 translation.

## Not pancake's fault, but it bit (recorded so the next builder is warned)

Base64 url-safe **no-pad** of N bytes is `(N*4 + 2) / 3` chars, not the padded
length. Sizing a buffer `[88]u8` for a 64-byte signature (padded length) left two
uninitialized bytes that rode the wire as a string argument, surfacing once as a
JSON UTF-8 error in the audit and once as a wire `InvalidCharacter` that looked like
a protocol bug. Use `std.base64.…Encoder.calcSize` and the returned slice. Fixed in
the app; noted because it cost real time to localize.

## Status of the larger deliverables

- **Two-party, on pancake's native runtime, end-to-end, one command:** done.
- **Refusal/accountability property proven:** done (step 6 of the run).
- **Three-party introduction (true caller survives a handoff):** done (in-memory
  protocol proof). `zig build accountability-three-party` proves that when A
  introduces B to C via `cross_peer.deliverGive`/`withdrawGift`, C's Episode
  attributes B (the true caller), not A. The over-TCP variant (three peers on
  three sockets) is the next frontier.
- **Reachable through foreign consumers via the C ABI:** done. Deno
  (`deno/caller.ts`) and Python (`python/caller.py`) each connect to the standalone
  Zig host (`zig/host.zig`) over real OCapN/TCP, generate their own Ed25519
  identity, sign the attestation, and invoke. Both fulfillment and refusal
  (`UnattestedCaller`) round-trip. Three languages, one OCapN wire. Run via
  `deno run --allow-ffi --allow-read --allow-net --allow-run deno/demo.ts`.
