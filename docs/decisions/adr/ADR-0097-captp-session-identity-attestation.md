---
id: ADR-0097
status: proposed
date: 2026-07-31
tags: [captp, handshake, identity, keyed-tcp, transport]
decision: "Every CapTP connection uses a fresh session signing key. Durable peer identity stays a netlayer concern: an authenticated transport supplies its peer key, while key-designator transports without that proof carry a durable-key signature authorizing the fresh session key. Session identity, durable peer identity, and verification provenance remain distinct throughout Host policy and application reporting."
supersedes: []
superseded_by: []
amends: [ADR-0068, ADR-0075, ADR-0093]
amended_by: []
---

# ADR-0097 CapTP session identity and durable-key attestation

## Status

This is a proposed companion to ADR-0096. pancake must not switch to fresh
session keys until the complete authentication chain and all keyed-TCP refusal
cases below are implemented. Until then the current key reuse remains an honest
boundary rather than a partially migrated security posture.

The new durable-key credential uses OCapN's locator-hint extension point but is
not yet an upstream OCapN convention. The checked OCapN finding is the pinned
hints-typing disagreement: the draft describes a mapping while Goblins accepts
only false or a string. The pancake extension itself requires corpus vectors,
live foreign decoding, and an upstream proposal before interoperability ships.

## Context

OCapN defines `session_pubkey` as the public half of a per-connection key pair.
Goblins generates a fresh pair for every CapTP session. pancake instead seeds
every session in a Host from one durable Host key. The reuse made handoff and
reconnect code convenient, but it collapsed two identities:

- the durable peer identity named by a locator; and
- the ephemeral CapTP session identity named by `session_pubkey` and signed
  handoff records.

Changing only the key generator would break keyed-TCP authentication. A
`keyed-tcp` locator's designator is the listener's durable Ed25519 key, while
the underlying TCP stream is cleartext and authenticates nothing. Its current
dial-side proof is exactly `session_pubkey == locator designator`. A fresh
session key makes that equality false and leaves no other proof that the
listener owns the durable key.

iroh has the needed lower-layer fact: QUIC authenticates the durable endpoint
key and protects the stream carrying the hello. WebRTC also has an authenticated
pipe: DTLS verifies the fingerprint exchanged through capability-authorized
signaling. Their current adapters do not expose those remote bindings to Host
verification. They have shared one equality check with cleartext transports
despite having different authentication mechanisms.

## Decision

### Every CapTP connection has a fresh key

Each `HostSession` receives a fresh Ed25519 signing seed from the adapter entropy
boundary. The sync no-I/O core generates no entropy. Native drivers draw the
seed while opening a connection; byte-fed C and Wasm Hosts receive it through
an explicit entropy action or caller-provided bytes; tests use deterministic
seeds.

The session key signs `acceptable_location` and every handoff record that names
that session. Reconnecting the same peers creates a different session public
key and therefore a different handoff session name. An old give cannot name the
new connection merely because the durable peers are unchanged.

### Key shape and authentication mechanism are separate contracts

`DesignatorScheme.key` continues to describe locator grammar. It no longer
means that the designator bytes must equal `session_pubkey`.

Each identity-aware netlayer declares how a durable designator is authenticated
and bound to the CapTP hello:

- **Authenticated transport.** iroh authenticates the durable endpoint key and
  protects the byte stream. WebRTC authenticates its DataChannel with the DTLS
  fingerprint exchanged through the OCapN signaling capability for the named
  peer. Their adapters surface the verified remote binding on dial and accept
  paths. Host installs it as pre-feed engine policy, and the inbound hello must
  name the same designator before session state mutates. WebRTC's missing proof
  is interim adapter work, not a reason to add a wire credential.
- **Durable-key attestation.** keyed-TCP and byte-transparent keyed-relay have a
  durable Ed25519 designator and no lower layer that can authenticate it. Their
  hello carries a signature by that durable key authorizing the fresh CapTP
  session key. This mechanism is permanent unless those transports gain an
  independently authenticated peer binding.
- **No durable authentication.** Plain TCP keeps address-based connection
  provenance and the ordinary CapTP hello signature. It does not claim a
  cryptographically authenticated durable peer.

The core receives the selected verification contract from the adapter before
the first byte is fed. The engine enforces it at the inbound hello chokepoint,
before session apply or any later frame in the same chunk. It does not infer
security from a transport string or from a key-shaped designator. The native
and byte-fed transport tables must assign every member of the
`DesignatorScheme.key` set owned by `designatorSchemeForTransport` a mechanism
before the equality pin can be removed.

### Durable-key transports carry a two-signature chain

A hello whose verification contract is durable-key attestation contains a
required `session-key-attestation` hint in its key-designator
`acceptable_location`. Its value is a 64-byte Ed25519 signature. The durable
peer key signs the canonical Syrup encoding of this domain-separated record:

```text
<session-key-attestation-v1 transport designator session-pubkey>
```

The fields are the exact locator transport and designator plus the 32-byte
CapTP session public key. The canonical record, rather than byte concatenation,
fixes field boundaries and gives Syrup and Cap'n Proto one verification domain.
The record label is the domain separator. A different transport, designator,
or session key invalidates the signature.

The ordinary CapTP session key still signs the complete
`acceptable_location`, including the attestation and routing hints. Verification
therefore establishes this static authorization chain:

1. the durable key authorizes this fresh session key for this locator identity;
2. the session key signed the complete advertised locator.

A receiver using durable-key attestation verifies, before the session opens and
before any later frame in the same input chunk is applied:

1. the designator parses as a durable Ed25519 key;
2. the required attestation verifies under that durable key for the received
   `session_pubkey`;
3. the ordinary `acceptable_location_sig` verifies under that session key.

A dial additionally requires the hello's `(transport, designator)` to equal the
expected locator identity. An accept has no dialed identity to compare. It
records the hello's durable identity only after both signatures verify, and
never indexes an unverified claim as a peer.

The attestation hint is session credential metadata, not another identity field
or a routing hint. Locator and sturdyref equality continue to ignore it. After
a signed handoff locator has been verified, `exporterLocatorUri` and every other
dial/URI projection omit `session-key-attestation` while preserving routing
hints such as `direct-addresses`. A stale credential must never enter a
sturdyref or poison URI projection; the next session creates its own.

The hint encoding is provisional. Canonical codec and signing vectors are
committed before implementation, and a live Goblins recipient must decode a
signed give whose pancake exporter locator carries the credential. The current
Goblins locator constructor accepts only false or string hints while the draft
describes hints as a mapping and pancake encodes a non-empty mapping as a Syrup
dict. pancake will propose the credential shape upstream before claiming
interoperability. If upstream selects another shape, pancake changes its
unshipped encoding and vectors; it does not freeze the provisional dict into
signed handoff locators.

The attestation and ordinary hello signature contain no challenge. They prove
that their keys authorized static records, not that a signer is live on this
TCP connection. keyed-TCP retains ADR-0075's whole-hello replay and active-relay
exposure. Fresh keys isolate honest reconnects and require possession for new
handoff signatures; they do not make the cleartext channel replay-safe. A
challenge or channel-binding protocol would be a separate wire decision.

### Identity reporting carries both identities

Host state retains these facts separately:

- `session_pubkey`, the exact CapTP session identity;
- peer `(transport, designator)`, the locator identity;
- verification provenance: authenticated transport peer, durable-key static
  authorization, or no cryptographic durable authentication.

`PartnerIdentity` reports all three. `designatorIsSessionKey` may remain as a
literal comparison for diagnostics, but it is no longer an authentication
predicate and keyed-TCP normally returns false. APIs that require durable peer
authentication ask the provenance-bearing predicate instead.

This amends ADR-0093: the signature under `session_pubkey` proves that session
key's claim about its locator. Durable ownership comes from the independent
transport proof or attestation.

### Crossed hellos and handoff use the right identity

Crossed-hello matching and crossed-hello ordering are separate operations:

1. Match an inbound hello to an outstanding outbound dial by verified durable
   peer identity where available, or by the OCapN-declared location on an
   address transport with its existing stated weakness.
2. Derive the two OCapN session identifiers from the outbound connection's
   fresh local `session_pubkey` and the inbound connection's fresh remote
   `session_pubkey`.
3. Sort their serialized identifiers and abort the lower session, exactly as
   the OCapN crossed-hellos algorithm requires.

Durable identity detects which two connection attempts race; fresh session
identity selects the winner. Neither substitutes for the other. Established
peer lookup and exact handoff-session lookup remain separate indexes. An
unverified partner-declared key is never promoted to durable Host identity.

The exact `session_pubkey` continues to name a handoff session, verify gives,
and index live session coordinators. It is never used as a reconnect-stable peer
id. On an honest reconnect, a fresh key means an old give does not name the new
session coordinator. A replayed complete keyed-TCP hello can revive its old
static session claim on another cleartext connection; this ADR does not claim
otherwise.

This amends ADR-0068's reused-Host-key assumption without discarding its
one-Host/many-session or crossed-hello structure. It amends ADR-0075's equality
pin into explicit transport proof or a two-signature chain, and ADR-0093's
partner report into a two-identity result.

## Required evidence

Acceptance requires:

1. Open two successive and two simultaneous sessions from one Host and prove
   every `session_pubkey` differs while the durable peer identity stays equal.
2. On keyed-TCP, accept a valid durable-key attestation and refuse a missing
   attestation, a signature by another durable key, and mutations of the
   transport, designator, or session key.
3. Feed a valid hello and a later frame in one chunk. Every failed keyed-TCP
   credential must refuse the hello before the later frame can apply.
4. Exercise both dial and accept halves. The listener creates the attestation
   from its durable seed; the dialer verifies it against the expected locator.
   The accept side verifies a remote attestation before recording that remote
   durable identity and refuses every negative case without indexing the claim.
5. Carry a credential-bearing keyed-TCP exporter locator through a signed
   pancake handoff. Verify the credential in the descriptor, omit it from
   URI/dial projection, preserve `direct-addresses`, and redeem successfully.
6. Carry the same locator through a live Goblins recipient's signed-give decode
   path and prove its locator constructor accepts the chosen interoperable
   hints shape. Goblins need not implement the keyed-TCP netlayer; an
   unsupported-netlayer result may follow only after successful decode.
7. Run iroh with fresh CapTP keys while its authenticated transport identity
   remains stable. Prove both dial and accept sidecar paths supply the remote
   endpoint id to pre-feed verification.
8. Run WebRTC with fresh CapTP keys while DTLS and capability-authorized
   signaling supply the pre-feed peer binding. Run keyed-relay with a fresh key
   and durable-key attestation. No key-designator transport remains
   authenticated only by the deleted equality rule.
9. Resolve crossed hellos between the same durable peers with fresh session
   keys. Prove matching uses peer identity, ordering uses the two session ids,
   the lower serialized id aborts, and both sides retain the same connection.
10. Reconnect the same nodes honestly and prove an old handoff certificate cannot
   resolve to the new session coordinator. Separately pin that replaying a whole
   keyed-TCP hello is outside this guarantee.
11. Report one `PartnerIdentity` through native Zig, C, Wasm, and every binding,
   proving the durable identity, session key, and verification provenance are
   not conflated.
12. Preserve the current keyed-TCP restart/squatter refusal matrix and the
   cleartext security statement in ADR-0075.

## Migration order

1. Check the pinned draft/Goblins hints-typing disagreement as an OCapN
   finding. Commit canonical codec bytes plus positive and mutation-negative
   signing vectors for the provisional credential, and propose its shape
   upstream before interoperability shipment.
2. Split designator grammar from netlayer authentication in the native and
   byte-fed adapter contracts. Expose iroh's authenticated remote endpoint id
   and WebRTC's capability-authorized DTLS binding on dial/accept paths. Add
   durable-key verification for keyed-TCP and keyed-relay while sessions still
   reuse keys.
3. Widen core and public partner identity to retain durable identity, session
   identity, and provenance. Split crossed-hello matching from fresh-session-id
   ordering, and split durable-peer lookup from handoff-session lookup.
4. Switch every session-opening path to fresh entropy in one green slice,
   including C, Wasm, bindings, iroh, keyed-TCP, WebRTC, keyed-relay, tests, and
   handoff fixtures.
5. Delete the equality pin as an authentication rule only after every sibling
   path proves its replacement.

## Scope (what this does not decide)

- keyed-TCP remains cleartext. The chain authenticates the durable
  advertisement and session signing authority as static records; it does not
  provide channel confidentiality, integrity, freshness, or replay resistance.
- Locator identity remains `(transport, designator)`. Hints remain outside
  equality even when one carries a required netlayer credential.
- This does not change OCapN handoff descriptor shapes or signature domains.
- Sturdyref peer matching is ADR-0098's decision.
- A future transport can supply another binding mechanism, but it must declare
  and test that mechanism explicitly.

## Alternatives Considered

- **Keep one durable key as every CapTP session key.** Rejected: it contradicts
  per-connection session identity and lets reconnect reuse handoff names.
- **Change fresh keys everywhere except keyed-TCP.** Rejected: CapTP session
  semantics would depend on the selected transport and keyed-TCP reconnects
  would retain the defect.
- **Demote keyed-TCP to unauthenticated.** Rejected: it discards the shipped
  four-binding restart and squatter-refusal matrix. Durable-key attestation
  preserves that possession check while still stating that cleartext TCP has
  no confidentiality, channel freshness, or replay resistance.
- **Treat any key-shaped designator as proof.** Rejected: syntax proves no key
  possession.
- **Add a keyed-TCP transport preface.** Rejected: it duplicates CapTP hello
  framing, forces the transport resident to learn CapTP session keys, and does
  not fit the byte-fed Host. The signed locator extension keeps verification at
  the existing before-open handshake chokepoint.
- **Sign only `session_pubkey`.** Rejected: the credential could be replayed
  under another transport or locator identity. The signature binds all three.

## Cost and lifetime posture

- Attestation lookup and verification use the borrowed hello view before
  session apply. An extra owned hint materialization is forbidden.
- Canonical attestation bytes are once-per-hello signing or verification
  scratch. Their allocation and copy count are named and measured.
- Syrup currently retains the signed raw locator for the session lifetime. The
  credential increases that retained size and must be charged to the warmed
  500,000-session footprint measurement rather than assumed negligible.
- Verification provenance and an authenticated transport id reuse retained
  locator/key bytes where lifetimes allow; duplicating the same identity bytes
  in another session allocation is forbidden without a measured reason.
- URI and handoff dial projection filter the credential during their existing
  materialization and add no second full-locator walk.

## Consequences

- Session entropy becomes per connection rather than per Host.
- The engine's expected-partner contract becomes a verification strategy over
  durable identity and session identity, not `expected_partner_key ==
  session_pubkey`.
- Locator hint codecs preserve the attestation bytes exactly, while equality
  and URI cache keys continue to ignore them. URI/dial projection removes the
  session credential after signed-descriptor verification.
- The iroh and WebRTC adapters expose their authenticated remote binding before
  CapTP bytes can apply. WebRTC does not carry the provisional credential.
- Host session registries distinguish durable peer lookup from exact CapTP
  session lookup.
- ADR-0068, ADR-0075, and ADR-0093 remain accepted in substance and are amended
  by this separation when this record is accepted.

## Notes

ADR-0096 owns Host-scoped capability identity and exact gifts. ADR-0098 owns
sturdyref peer authority. Neither requires pancake to claim fresh session keys
before the keyed-TCP chain is complete.
