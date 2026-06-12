# Friction log — building the first real app on pancake

This is the record of where the first real pancake application was harder to
build than it should have been, what that cost, and what changed as a result. It
is a historical friction log, not a first-read contract. Newer notes come first
within each section.

## Fixed

### 2. A refused frame's cause was hard to see through the adapter (engine, fixed)

**Symptom.** `net_adapter.Connection.pump` flattens every session-authority
refusal to `PumpError.ProtocolAbort`, dropping the typed cause. When the
broken-promise encode above failed, the only signal a consumer got was
`ProtocolAbort` with an empty reason; the typed cause was only recoverable by
driving `peer.step()` directly, outside the connection. Cost paid that round:
most of the debugging time.

**Fix.** The peer keeps the typed cause readable. `engine.Peer.lastAbort()`
returns the codec-vs-session domain, the projected `op:abort` kind, the static
diagnostic, and the originating error name. It is recorded on every dispatch
failure, whether the failure happens while refusing inbound data or encoding
outbound data. The adapter is unchanged: `ProtocolAbort` still names only the
family, and the consumer reads the specific member from the peer it already holds,
so it does not race the closing socket. The C ABI exposes the same information
through `pancake_peer_last_abort`, whose `PancakeLastAbort` carries the domain,
the abort kind's wire name, and the diagnostic. A binding can now diagnose a
refusal as precisely as native Zig.

### 3. No vat-level "publish as bootstrap, fetch by name" (driver, fixed)

**Symptom.** The app agreed on an export id (`AFFORDANCE_EXPORT = 5`) on both
sides out of band. That is fine for a two-peer worked example, but a stranger
does not know your export ids — they `fetch` a capability by swissnum from your
bootstrap object.

**Fix.** The application surface owns both halves. `driver.ConnectedVat.publish`
puts an actor behind a swissnum, and `fetch` resolves a partner's name to a far
ref. The bindings' `Connection`s expose the same verbs. Every part of this demo
uses the name `"affordance"`: the Zig-native demo, the standalone host, and the
Deno and Python callers. No export id is agreed out of band anywhere in the app.

### 4. The C ABI and the native Zig path disagreed on session state (bindings, fixed)

**Symptom.** The C ABI created peers in `open` state (no handshake) while native
Zig `initNegotiating` expected a keyed `op:start-session` exchange, so the
standalone host had to drop out of the negotiating state to be reachable from
Deno, and the cross-seam demo ran without the V1.0 profile.

**Fix.** The C ABI creates authenticated v1.0 negotiating peers.
`pancake_peer_start_session` signs and queues the hello, and `connect` in the Deno
and Python bindings completes the keyed handshake before returning. The
standalone host now accepts with the same negotiating peer and profile the
native-only demo uses through `driver.acceptTcp`. One host shape serves both kinds
of caller, and the refusal path, a V1.0 broken promise, crosses the boundary in
both demos.

### 1. The Goblins V1.0 wire could not carry a *broken* promise (codec, fixed)

**Symptom.** The whole point of accountability is refusing a caller you cannot
attest. The first time the host refused, turning an unattested signature into a
broken promise, the host's session aborted the conversation with `ProtocolAbort`
instead of delivering the refusal.

**Root cause.** Under the canonical Goblins V1.0 profile, a resolution travels as
a resolver-callback `op:deliver` whose args are `['fulfill payload]` or
`['break <error>]`. The Syrup codec could decode an `<error ...>` record in
argument position, where `readNeutralArgument` produces an `.@"error"`, but
`writeArgument` had no matching arm. Encoding the `break` args therefore failed
with `UnsupportedArgument`. pancake could read a broken-promise argument it could
not write.

**Fix.** Added the symmetric `.@"error"` arm to `writeArgument` (it reuses the
existing `writeError`), plus a round-trip test in `test/codec/syrup_test.zig`. The
switch is now exhaustive over `model.Argument`, so a future variant fails the build
rather than silently hitting an `else`. This is a bug fix restoring symmetry, not a
new affordance — it stays inside the codec boundary.

**Why it mattered.** The refusal path is the security-relevant half of the feature.
Without this, pancake could express "yes" over V1.0 but not "no, I won't account
for you." That refusal is exactly the message a capability-secure system most
needs to send.

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

## Not pancake's fault, but it bit (recorded so the next builder is warned)

Base64 url-safe **no-pad** of N bytes is `(N*4 + 2) / 3` chars, not the padded
length. Sizing a buffer `[88]u8` for a 64-byte signature (padded length) left two
uninitialized bytes that rode the wire as a string argument, surfacing once as a
JSON UTF-8 error in the audit and once as a wire `InvalidCharacter` that looked like
a protocol bug. Use `std.base64.…Encoder.calcSize` and the returned slice. Fixed in
the app; noted because it cost real time to localize.

## Status of the larger deliverables

- **Two-party application on pancake's native runtime.** Done. It runs end to end
  with one command.
- **Refusal and accountability property.** Done. Step 6 of the run proves it.
- **Three-party introduction, where the true caller survives handoff.** Done as an
  in-memory protocol proof. `zig build accountability-three-party` proves that
  when A introduces B to C through `cross_peer.deliverGive` and `withdrawGift`,
  C's Episode attributes B, the true caller, not A. The over-TCP variant with
  three peers on three sockets remains outside this log.
- **Foreign consumers through the C ABI.** Done. Deno (`deno/caller.ts`) and Python
  (`python/caller.py`) each connect to the standalone Zig host (`zig/host.zig`)
  over real OCapN/TCP, generate their own Ed25519 identity, sign the attestation,
  and invoke. Both fulfillment and refusal (`UnattestedCaller`) round-trip. That
  is three languages on one OCapN wire. Run it with
  `deno run --allow-ffi --allow-read --allow-net --allow-run deno/demo.ts`.
