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
decision: Three-party handoff works end to end. Ed25519 signatures over OCapN-canonical `desc:*` records, a session-owned gift table with deposit / withdraw, recipient-match and monotonic handoff-count replay rejection, and cross-peer routing in caller-orchestrated free functions outside the per-peer dispatcher. Signature verification is an injected hook; signatures cover decoded fields, so a re-encode does not invalidate them.
supersedes: []
superseded_by: [ADR-0056]
---

# ADR-0009 Three-party handoff substrate

> **Scope of supersession.**
> [ADR-0056](ADR-0056-vat-scoped-gift-registry.md) replaces only the
> session-owned gift tables with the vat-scoped registry. The Syrup signing
> domain, the `desc:sig-envelope` shape, replay rejection, and the cross-peer
> routing design recorded here remain current, and living docs cite this
> record for them.

## Context

A three-party handoff lets a gifter give a recipient a reference to an object
hosted by an exporter the gifter already reaches. The OCapN
`CapTP Specification.md` (§ Third-party handoffs) and Goblins's `captp.rkt` pin
the `desc:sig-envelope` / `desc:handoff-give` / `desc:handoff-receive` records
and the bootstrap deposit / withdraw flow precisely, so the wire half is a
transcription. pancake's calls are where signature verification lives, where the
gift bookkeeping lives, and how a flow that spans several sessions stays free of
shared mutable state.

Engages the [First Principles](../../../AGENTS.md#first-principles): _session
state is authoritative_ (the gift table and replay rejection live in the
session, not the codec), _codecs parse and render but do not own authority_
(verification is injected at the boundary, never invoked from the codec), _the
portable core stays sync and no-I/O_ (cross-peer routing is caller-orchestrated
and the core pulls in no crypto dependency), and _conformance is load-bearing_.

## Decision

### Wire shapes

The Syrup codec
([`src/ocapn/codec/syrup/mod.zig`](../../../src/ocapn/codec/syrup/mod.zig))
renders and parses three nested records. `desc:sig-envelope` is two fields: the
signed payload object and its signature: with no embedded pubkey; the verifier
knows the signing key out of band. `desc:handoff-give` carries `recipient-key`,
`exporter-location`, `gifter-exporter-session`, `gifter-side`, `gift-id`.
`desc:handoff-receive` carries `receiving-session`, `receiving-side`,
`handoff-count`, and the nested gifter-signed `signed-give`.
`handoffViewToOwned` / `readSignedHandoff` walk the envelope into the owned
model; `writeSignedGive` / `writeSignedReceive` render it back. The signature
rides as the gcrypt `sig-val eddsa r s` shape.

### Ed25519 signatures over decoded fields

[`src/foundation/crypto.zig`](../../../src/foundation/crypto.zig) owns the
Ed25519 `sign` / `verify` over caller-supplied canonical bytes, the fixed-width
`PeerKey` / `Signature`, and the SHA256² Public Identifier derivation. The core
treats a signature as opaque bytes: verification is an **injected hook**
(`SignatureVerifier` in
[`src/ocapn/engine/cross_peer.zig`](../../../src/ocapn/engine/cross_peer.zig))
supplied by the caller, so the no-I/O core depends on no crypto. Signatures
cover the **decoded fields** of the signed object, not its encoded bytes, so
re-rendering the same record produces a signature-preserving frame: the
cross-codec re-encode contract
([ADR-0003](ADR-0003-codec-interoperability-posture.md)). Entropy is not in the
core: a key seed and the `gift-id` come from the adapter boundary.

### Session-owned gift table

The exporter session is the authority for whether a withdrawal is allowed
([`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig)).
`depositGift` records a `GiftEntry { gift_id, recipient_key, withdrawn }` and
rejects duplicate ids. `validateInboundWithdraw` checks gift existence, that the
gift is not already withdrawn, that the asserted `recipient_key` matches the
deposited one, and that the `handoff_count` is strictly greater than the last
accepted count for that receiving session: a replay or out-of-order withdrawal
fails loud with `HandoffReplay`. `applyInboundWithdraw` records the count (the
one fallible step) then marks the gift withdrawn, so the apply stays atomic.
`SessionLimits` caps the deposited-gift and seen-handoff-count tables against a
hostile peer ([ADR-0025](ADR-0025-session-table-cap-policy.md)).

### Cross-peer routing is caller-orchestrated

A `Peer` owns exactly one direct session, so a three-vat handoff spans several
peers: the gifter-to-recipient session, the recipient-to-exporter session, and the
exporter session that authorizes the withdrawal. Routing lives in free functions
in [`src/ocapn/engine/cross_peer.zig`](../../../src/ocapn/engine/cross_peer.zig)
`deliverGive` (the exporter records the gift, then the gifter sends the signed
give to the recipient) and `withdrawGift` (the injected verifier checks the
recipient's signature, then the recipient sends the receive to the exporter,
whose session authorizes it). Each takes a `*Peer` per participating session;
this is **not** inside the per-peer dispatcher. The borrow checker enforces that
no two participants alias, so there is no shared mutable state and no lock
discipline.

### Relayed-resolution forwarding

A handoff can import a promise hosted by a third party. An `op:listen` on that
import installs a listener against the third-party-hosted import
(`imported_promises` in the session). CapTP-normal listen uses
`<desc:export N>` (receiver `.near`); `<desc:import-promise N>` (receiver
`.far`) is the same row. When the introducing session forwards the host's
resolution, `Peer.applyRelayedResolution` stores it and fires installed
listeners, so a late `op:listen` fires immediately rather than waiting for a
resolution that already arrived. A relayed resolution is the promise's one
settled value: a second relay for an already-settled import is refused
(`Error.UnexpectedMessage`), mirroring the answer-side resolve-once rule, so
every listener (installed before or after the relay) observes the same value.

The engine exposes that seam (`installThirdPartyImport`,
`Peer.applyRelayedResolution`). `engine.Node` owns the introducing-session
promise proxy; `driver_core.Host` drives it when an answer would fulfill with a
foreign **promise** token (`proxyForeignPromiseFulfill` /
`claimProxyListenerFire`). Foreign **object** fulfills stay on
`interceptFulfilledRef` gift redeem. Stamp/GC races (enroll-stamped `row_id`
applied after session mutation) live in
`test/engine/relay_resolution_test.zig`; Node end-to-end proxy scenarios live in
`test/engine/node_test.zig`.

Implemented choreography:

1. **Preserve promise identity across enrollment.** `Node.enrollForeign`
   returns a token whose `RefKind` matches the enrolled wire ref.
2. **Re-export without forcing a gift redeem.** `proxyForeignPromiseFulfill`
   mints an import-promise via `allocatePromiseExport` +
   `installThirdPartyImport` and returns a near-promise rewrite for the vat.
3. **Subscribe on the home session.** One `op:listen` per home wire import
   (shared across recipient introduces of that wire); refused with
   `session_not_open` when the home peer is not yet open (CapTP break reason
   via `@errorName`).
4. **Forward once.** `consumeProxyListenerFire` takes the Host-owned
   resolution as fire owner, settles every recipient store (N=1 **moves**;
   N>1 each store materializes via `materializeResolutionForStore`), and
   tears the proxy down after settle. Matches memory.md: one home listen,
   named materialize into N session stores, not N listens and not a public
   `cloneResolution` spine.

### Signature verification and gifter-key provenance

Handoff signature verification runs in the engine on an injected
`SignatureVerifier` seam (same pattern as `op:start-session`). pancake ships
the canonical signable-bytes encoders;
[`codec.syrup`](../../../src/ocapn/codec/syrup/encode.zig) provides
`canonicalHandoffGiveSignedBytes` and `canonicalHandoffReceiveSignedBytes`,
single-sourced against the wire encoders so the signing domain can never drift
from what goes on the wire. `cross_peer.withdrawGift` verifies each certificate
over its full canonical envelope through that injected verifier, not over the
gift-id field alone, because a single field is forgeable by replay across
envelopes. Production paths wire `foundation.crypto`;
`testOnlyAcceptingVerifier` is for in-process tests and trusted substrates only.

The exporter's gift record carries the depositing gifter's session public key as
opaque provenance. `Session.depositGift` records a `gifter_key` beside the
recipient key, and `Session.giftGifterKey` reads it back, so a withdrawal routes
each certificate to the right key: the give to the gifter key the exporter
recorded at deposit, and the receive to the recipient key the give names. The
exporter learns that gifter key automatically from the handshake. The session
records its partner's session public key when it applies the partner's
`op:start-session` and exposes it as `Session.partnerSessionKey`, and
`cross_peer.deliverGive` falls back to that learned key when none is threaded
explicitly. The session stores the key as opaque bytes and runs no crypto;
verification is the injected hook's job. `test/engine/cross_peer_test.zig`
proves an end-to-end real-Ed25519 withdrawal authorized against the key the
exporter learned from the handshake, and refuses a give signed by any other key
with `SignatureRejected`.

The live boundary now includes a three-party handoff against Goblins with
pancake as the recipient: `zig build goblins-handoff` enlivens a Goblins
introducer, receives a Goblins-hosted cap by `desc:handoff-give`, dials the
exporter, presents a signed `desc:handoff-receive`, withdraws the cap, and calls
it. The cross-session gift forwarding that supports a pancake exporter lives in
the bootstrap handoff registry used by the OCapN conformance peer.

## Scope (what this does not decide)

- Cross-codec handoff re-encode and re-verify ship
  (`test/engine/cross_peer_test.zig`; see also `docs/boundaries.md`), including
  Cap'n Proto structural exporter locators (`#f` / `direct-addresses`). That
  Cap'n Proto path is pancake-to-pancake completeness, not a Goblins parity
  claim.
- Real cryptographic verification: the injected `SignatureVerifier` is the seam;
  production defaults to `foundation.crypto`; the bundled accept-everything
  verifier is for in-process tests and trusted substrates only.
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
  is two fields; the verifier already knows the key out of band, and a pubkey
  field would diverge from Goblins.
- **Run cross-peer coordination inside the per-peer dispatcher.** Rejected: a
  `Peer` owns one session; coordinating several needs the borrow checker to
  police exclusivity, which free functions taking distinct `*Peer`s give without
  a shared owner.
- **Saturating or silent handoff-count handling.** Rejected: a duplicate or
  backwards count is a replay; rejecting loud with `HandoffReplay` surfaces it
  in a scenario, not a deploy.
- **Pull a crypto dependency into the core.** Rejected: verification is
  injected, so the portable core stays no-I/O and dependency-free.

## Consequences

- [`src/foundation/crypto.zig`](../../../src/foundation/crypto.zig) owns Ed25519
  sign / verify, `PeerKey` / `Signature`, and the SHA256² identifier derivation;
  it allocates nothing and compiles to `wasm32`.
- [`src/ocapn/engine/cross_peer.zig`](../../../src/ocapn/engine/cross_peer.zig)
  owns the `SignatureVerifier` injection seam for host-driven handoff routing.
- [`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig) owns the
  gift table, `validateInboundWithdraw` / `applyInboundWithdraw`
  (validate-then-apply, atomic), monotonic handoff-count replay rejection, and
  the deposited-gift / handoff-count caps.
- [`src/ocapn/codec/syrup/mod.zig`](../../../src/ocapn/codec/syrup/mod.zig)
  renders and parses the three `desc:*` records; the signature rides as the
  gcrypt `sig-val`.
- Conformance for give / withdraw end to end, replay rejection, and recipient
  mismatch covers Zig scenarios, the upstream OCapN suite's
  `third_party_handoffs`, and live Goblins object handoff/gift. Relayed
  resolution / introducing-session promise proxy is proven by Zig scenarios
  (`test/engine/relay_resolution_test.zig`, `test/engine/node_test.zig`) and
  Host intercept; it is not covered by live `goblins-handoff` /
  `goblins-gift` (those prove object redeem/mint) nor by oracle fixtures.

## Forward compatibility

These are pancake's current `v1_0` compatibility shapes; an upstream change may
revise that projection, not the model. A second codec inherits the decoded-field signing
contract: it must canonicalize the signed object to the same bytes for
verification, regardless of its own wire shape.

## Notes

[ADR-0056](ADR-0056-vat-scoped-gift-registry.md) supersedes the session-owned
gift table decided here: gift and handoff-count authority now lives in the
vat-scoped `engine.bootstrap.GiftRegistry`, and a re-deposit replaces the prior
row instead of being rejected. The wire shapes, decoded-field signing,
cross-peer routing, and gifter-key provenance in this ADR remain in force.

[ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) is the sibling
Syrup-profile work; the `handoff_replay` and `invalid_handoff_signature` abort
kinds live in its taxonomy.
[ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the profile posture
these records sit inside.
