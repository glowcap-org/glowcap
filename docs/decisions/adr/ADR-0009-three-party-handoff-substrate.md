---
id: ADR-0009
status: superseded
date: 2026-05-05
tags: [
  handoff,
  three-party,
  crypto,
  ed25519,
  sig-envelope,
  cross-peer,
  goblins-parity,
]
decision: Three-party handoff works end to end. Ed25519 signatures over OCapN-canonical `desc:*` records, a session-owned gift table with deposit / withdraw, recipient-match and monotonic handoff-count replay rejection, and cross-peer routing in caller-orchestrated free functions outside the per-peer dispatcher. Signature verification is an injected hook. Signatures cover decoded fields, so a re-encode does not invalidate them.
supersedes: []
superseded_by: [ADR-0056]
amended_by: [ADR-0116]
---

# ADR-0009 Three-party handoff substrate

> **Scope of supersession.**
> [ADR-0056](ADR-0056-vat-scoped-gift-registry.md) historically replaced the
> session-owned gift tables with a vat-scoped registry. That authority choice
> is superseded by [ADR-0100](ADR-0100-session-owned-handoff-authority.md), so
> session-owned gifts and replay counters are current again. The Syrup signing
> domain, the `desc:sig-envelope` shape, replay rejection, and three-session
> choreography remain current. The original free-function router and copied-key
> provenance do not: `engine.Node` routes the live sessions, and
> [ADR-0100](ADR-0100-session-owned-handoff-authority.md) makes withdrawal
> resolve the Gifter–Exporter Peer and borrow its key and gift table directly.

## Context

A three-party handoff lets a gifter give a recipient a reference to an object
hosted by an exporter the gifter already reaches. The OCapN
`CapTP Specification.md` (§ Third-party handoffs) and Goblins's `captp.rkt` pin
the `desc:sig-envelope` / `desc:handoff-give` / `desc:handoff-receive` records
and the bootstrap deposit / withdraw flow, so the wire half is a transcription.
glowcap decides where signature verification lives, where the gift bookkeeping
lives, and how a flow that spans several sessions avoids shared mutable state.

## Decision

### Wire shapes

The Syrup codec
([`src/ocapn/codec/syrup/mod.zig`](../../../src/ocapn/codec/syrup/mod.zig))
renders and parses three nested records. `desc:sig-envelope` is two fields: the
signed payload object and its signature, with no embedded pubkey. The verifier
knows the signing key out of band. `desc:handoff-give` carries `recipient-key`,
`exporter-location`, `gifter-exporter-session`, `gifter-side`, `gift-id`.
`desc:handoff-receive` carries `receiving-session`, `receiving-side`,
`handoff-count`, and the nested gifter-signed `signed-give`.
`handoffViewToOwned` / `readSignedHandoff` walk the envelope into the owned
model. `writeSignedGive` / `writeSignedReceive` render it back. The signature
rides as the gcrypt `sig-val eddsa r s` shape.

### Ed25519 signatures over decoded fields

[`src/foundation/crypto.zig`](../../../src/foundation/crypto.zig) owns the
Ed25519 `sign` / `verify` over caller-supplied canonical bytes, the fixed-width
`PeerKey` / `Signature`, and the SHA256² Public Identifier derivation. The
engine verifies with the authenticated live session key while remaining sync
and no-I/O. Signatures cover the decoded fields of the signed object, not its
encoded bytes, so re-rendering the same record produces a signature-preserving
frame (the cross-codec re-encode contract,
[ADR-0003](ADR-0003-codec-interoperability-posture.md)). A key seed and the
`gift-id` come from the adapter, since the core has no entropy.

### Session-owned gift table

Every `engine.Peer` owns one `engine.bootstrap.gifts.GiftRegistry`. The
Gifter–Exporter Peer owns deposited rows. The Receiver–Exporter Peer owns the
accepted and emitted scalar handoff counts. Validation checks gift existence,
recipient provenance when the deposit supplied it, receiving-session names,
and a strictly increasing `handoff_count`. Settlement queues its owned answer
before the infallible commit removes the gift. An early verified receive parks
only the fixed certificate subset and exact gift id needed after deposit, not
the signatures, locator, or raw signed envelope. Row and retained-byte limits
bound waiting. ADR-0100 owns the current authority and lifetime detail.

### Cross-peer routing

A `Peer` owns one direct session, so a three-vat handoff spans several peers:
the gifter-to-recipient session, the recipient-to-exporter session, and the
exporter session that authorizes the withdrawal. `engine.Node` owns the sans-I/O
live-session directory and routes redemption actions among those Peers.
`driver_core.Host` pumps them. The deposit and replay tables remain on their
owning Peers. Node keeps only authority-neutral exact-gift scheduler keys, so a
deposit or gifter close wakes the affected Receiver–Exporter Peers without
moving capability authority into the router.

### Relayed-resolution forwarding

A handoff can import a promise hosted by a third party. An inbound `op:listen`
on that promise must name a near target (`desc:export` / `.near` or
`.promise`): the session refuses an inbound `.far` listen target as
`InvalidReference`, because CapTP listen descriptors do not put a far promise
in the target slot. Outbound `listenOnFar` addresses the partner with a far
reference that encodes as their `desc:export`. When a third-party import is
installed (`imported_promises`) and the introducing session forwards the host's
resolution, `Peer.applyRelayedResolution` stores it and fires installed
listeners, so a late `op:listen` fires immediately. A relayed resolution is the
promise's one settled value: a second relay for an already-settled import is
refused (`Error.UnexpectedMessage`), mirroring the answer-side resolve-once
rule, so every listener observes the same value.

The engine exposes that seam (`installThirdPartyImport`,
`Peer.applyRelayedResolution`). `engine.Node` owns the introducing-session
promise proxy through its internal `node/proxies/` admission, topology, and
settlement owners. `driver_core.Host` drives the supported Node aliases when an
answer would fulfill with a foreign promise token
(`proxyForeignPromiseFulfill` / `projectProxyListenerFire`). Foreign object
fulfills stay on `interceptFulfilledRoute` gift redeem. Stamp/GC races
(enroll-stamped `row_id` applied after session mutation) are tested in
`test/engine/relay_resolution_test.zig`. Node end-to-end proxy scenarios live
under `test/engine/node/` (`proxy_test.zig`, `relay_test.zig`).

The choreography:

1. **Preserve promise identity across enrollment.** `Node.enrollForeign`
   returns a token whose `RefKind` matches the enrolled wire ref.
2. **Re-export without forcing a gift redeem.** `proxyForeignPromiseFulfill`
   mints an import-promise via `allocatePromiseExport` +
   `installThirdPartyImport` and returns a near-promise rewrite for the vat.
3. **Subscribe on the home session.** One `op:listen` per home wire import
   (shared across recipient introduces of that wire). Refused with
   `SessionNotOpen` when the home peer is not yet open (CapTP break reason
   via `@errorName`).
4. **Project once per recipient.** The Host lifts the consumed home fire to
   opaque identity once. `projectProxyListenerFire` lowers that complete value
   independently for each recipient through the inline-Passable batch owner,
   then tears down the proxy. There is one home listen and one bounded recipient
   materialization.
5. **Retire at logical close.** Closing the home spends every recipient's
   admission-time terminal escrow before removing the one-listener topology.
   Closing a recipient retires only that recipient and its reserved action.
   Node teardown does the same while borrowed Peer stores are still reachable,
   including a fire already parked in the shared Passable transaction.

### Signature verification and gifter-key provenance

Handoff signature verification runs in the engine against the live session
keys. glowcap ships the canonical signable-bytes encoders.
[`codec.syrup`](../../../src/ocapn/codec/syrup/encode.zig) provides
`canonicalHandoffGiveSignedBytes` and `canonicalHandoffReceiveSignedBytes`,
single-sourced against the wire encoders so the signing domain cannot drift
from the wire. `bootstrap.resolveForWithdraw` verifies both full
canonical envelopes, not the gift-id field alone. It resolves the signed side
and session name through the Host's authenticated live-session directory, then
uses that Gifter–Exporter Peer's handshake key for the give and the give's
recipient key for the receive. No gift row copies a gifter key.
`test/engine/cross_peer/authority_test.zig` proves the real-Ed25519 path and refuses a
certificate signed by another key.

Live interop covers a three-party handoff against Goblins with glowcap as the
recipient: `zig build goblins-handoff` enlivens a Goblins
introducer, receives a Goblins-hosted cap by `desc:handoff-give`, dials the
exporter, presents a signed `desc:handoff-receive`, withdraws the cap, and calls
it. The cross-session gift forwarding that supports a glowcap exporter lives in
the bootstrap handoff registry used by the OCapN conformance peer.

## Scope (what this does not decide)

- Cross-codec handoff re-encode and re-verify ship
  (`test/engine/cross_peer/`, see also `docs/boundaries.md`), including
  Cap'n Proto structural exporter locators (`#f` / `direct-addresses`). That
  Cap'n Proto path is glowcap-to-glowcap only.
- Real cryptographic verification uses `foundation.crypto` and the live
  session keys selected by `bootstrap.resolveForWithdraw`.
- The handshake substrate, bootstrap-fetch, and the `op:start-session` Ed25519
  signing the deposit / withdraw `op:deliver`s reuse,
  [ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md).
- Promise pipelining and the `op:listen` core semantics relayed resolution
  builds on, [ADR-0007](ADR-0007-promise-pipelining-substrate.md).
- GC / abort wire shapes and the `handoff_replay` abort kind,
  [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md).
- Sturdyref enliven dedup, a sibling cross-peer concern that is not handoff,
  [ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md).

## Alternatives Considered

- **Sign the encoded bytes per codec.** Rejected: a re-encode would then need
  re-signing, impossible without the secret key. Signing decoded fields keeps a
  future re-encode signature-preserving.
- **Embed the signer pubkey in `desc:sig-envelope`.** Rejected: the wire shape
  is two fields. The verifier already knows the key out of band, and a pubkey
  field would diverge from Goblins.
- **Run cross-peer coordination inside the per-peer dispatcher.** Rejected: a
  `Peer` owns one session, and coordinating several needs the borrow checker to
  police exclusivity, which free functions taking distinct `*Peer`s give without
  a shared owner.
- **Silent handoff-count handling.** Rejected: a duplicate or backwards count is
  a replay, and `HandoffReplay` surfaces it in a scenario, not a deploy.
- **Pull a crypto dependency into the core.** Rejected: verification is
  injected, so the portable core stays no-I/O and dependency-free.

## Consequences

- [`src/foundation/crypto.zig`](../../../src/foundation/crypto.zig) owns Ed25519
  sign / verify, `PeerKey` / `Signature`, and the SHA256² identifier derivation.
  It allocates nothing and compiles to `wasm32`.
- [`src/ocapn/engine/bootstrap.zig`](../../../src/ocapn/engine/bootstrap.zig)
  owns gift validation, canonical signature verification, pending-withdraw
  materialization, and validate-queue-commit settlement.
- Each `engine.Peer` owns its gift registry and scalar replay counters.
  `engine.Node` owns only the live-session route and authority-neutral wake
  dependencies described by ADR-0100.
- [`src/ocapn/codec/syrup/mod.zig`](../../../src/ocapn/codec/syrup/mod.zig)
  renders and parses the three `desc:*` records. The signature rides as the
  gcrypt `sig-val`.
- Conformance for give / withdraw end to end, replay rejection, and recipient
  mismatch covers Zig scenarios, the upstream OCapN suite's
  `third_party_handoffs`, and live Goblins object handoff/gift. Relayed
  resolution / introducing-session promise proxy is proven by Zig scenarios
  (`test/engine/relay_resolution_test.zig`, `test/engine/node/relay_test.zig`) and
  Host intercept. It is not covered by live `goblins-handoff` /
  `goblins-gift` (those prove object redeem/mint) nor by oracle fixtures.

## Forward compatibility

These are glowcap's current `v1_0` compatibility shapes. An upstream change may
revise that projection, not the model. A second codec inherits the
decoded-field signing contract: it canonicalizes the signed object to the same
bytes for verification, whatever its wire shape.

## Notes

[ADR-0100](ADR-0100-session-owned-handoff-authority.md) supersedes
[ADR-0056](ADR-0056-vat-scoped-gift-registry.md)'s vat-scoped authority:
gift and handoff-count state lives on the owning CapTP Peers again, and a
same-session re-deposit replaces the prior row instead of being rejected. The
wire shapes, decoded-field signing, and cross-peer routing in this ADR remain
in force. Withdrawal resolves and borrows provenance from the live
Gifter–Exporter Peer, with no copied key.

[ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) is the sibling
Syrup-profile work. The `handoff_replay` and `invalid_handoff_signature` abort
kinds live in its taxonomy.
[ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the profile posture
these records sit inside.
