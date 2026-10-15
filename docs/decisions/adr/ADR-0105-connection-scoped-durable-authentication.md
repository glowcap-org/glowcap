---
id: ADR-0105
status: accepted
date: 2026-08-04
tags: [captp, handshake, identity, transport, relay, iroh, webrtc, keyed-tcp]
decision: "Durable authentication is a property of the realized connection, not its transport name. A matching authenticated-channel key supplies positive provenance. A dial target is only a requirement. ADR-0109 retires the durable-key hint credential, so claims without channel proof remain unauthenticated."
supersedes: []
superseded_by: []
amends: [ADR-0097]
amended_by: [ADR-0109, ADR-0113]
---

# ADR-0105 Connection-scoped durable authentication

## Status

Accepted for the rule that authentication belongs to the realized connection.
ADR-0109 removes the durable-key credential branch. Current provenance is
either matching authenticated-channel proof or unauthenticated. The partner's
verified session key, its signed locator claim, and channel provenance are
separate facts. A dial's expected key constrains the acceptable claim but does
not authenticate it. ADR-0109 limits that comparison to a selected
key-designator route. A selected address route describes independent ingress.

The Context through Notes below preserve the design and rollout as adopted.
Present-tense references there to `session-key-attestation`, credentials,
attested partner keys, or `.durable_key_attestation` are historical and do not
describe current glowcap behavior.

## Context

ADR-0097 split designator grammar from authentication mechanism, then assigned
the mechanism per transport symbol. `driver_core.vocab.authenticationMechanismForTransport`
maps `keyed-tcp` and `keyed-relay` to a hello credential, `iroh` and `webrtc` to
a transport proof, and everything else to nothing. Two decisions read that
table. `driver_core.sessions.helloAndEnroll` consults it to decide whether to
mint a `session-key-attestation` for the designator this side advertises, and
`driver_core.sessions.mintShell` consults it to decide whether to install
`engine.Peer.requirePartnerAttestation` for the claim the partner will make.

A transport name does not imply that the code realizing the connection can
prove anything. Same name, no resident. The browser peer of ADR-0070 is the
clearest case. It dials a member's `iroh` locator through the byte-transparent
relay of ADR-0086, so the transport string reaching its Host is `iroh`, exactly
as on a native QUIC dial. It has no iroh resident and cannot verify a QUIC
remote. The far end holds the same table, sees `iroh`, and mints no credential
because the table says the transport will prove the name. No lower layer
records a verified remote either, so `driver_core.publish.durableProvenance`
answers `.unauthenticated`. The dialer asked for a specific durable identity,
opened a session, and can prove nothing about who answered.

Three more instances of the same shape are live in the tree, which is what makes
this a class rather than a browser bug.

- The blocking face derives the pin basis from the resident's declaration
  (`driver.blocking_session.connectVia` reading `nl.authentication()`), while the
  owning `driver.HostRuntime` face installs only `.dial_expectation` and the iroh
  resident's own `residentDial` never upgrades it. The same iroh dial to the same
  node reports `.authenticated_transport` through one driver face and
  `.unauthenticated` through another.
- A binding-hosted iroh listener has an end-to-end QUIC connection and no way to
  say so. The C ABI exports no seam for a verified remote key, and
  `glowcap_iroh_netlayer_try_accept` surfaces no remote node id, so every
  binding's iroh session reports a fact weaker than the one it holds.
- A key-designator dial pins `expected_durable_key`, and the pre-open check in
  `engine.inbound` refuses a hello claiming a *different* key. A hello claiming
  an *address* passes. A relay that dials some other node reaches a peer whose
  hello advertises the unreachable-client placeholder, and the session opens.
  The dialer named an identity and got a session to whoever answered.

`AGENTS.md`'s Names rule is the diagnosis. A key of `[]const u8` carries the
namespace it belongs to and neither of the other two dimensions, and the
costliest defects in this core have all been one missing dimension. A transport
symbol names a locator grammar and a wire family. It was standing in for "what
proved this partner", which is a property of one connection at one moment,
decided by whoever realized it.

The transport symbol cannot be repaired by renaming, either. The locator
identity is `(transport, designator)`, the attestation record binds that exact
transport string, the hello signature covers the encoded location, and the
pinned Goblins withdrawal lookup resolves a give by the exporter's
hello-declared location. The transport in a locator names the *peer's* address
family, never the path a dialer's bytes took to reach it.

## Decision

Authentication of a durable identity is connection-scoped. Three facts, each
owned by the layer that holds it, and the transport table is deleted.

### 1. What this side advertises, it attests

A hello whose own location designator has key form carries a
`session-key-attestation`, on every transport. The mint condition is possession,
not a transport row, and it is evaluated where the hello is assembled:
`engine.Peer.sendKeyedStartSession` mints when the advertised designator names
the durable key its caller supplied. The mint moves *into* the send rather than
staying a helper each assembler calls, because a helper is a step an assembler
can omit and several already had. The durable identity is a parameter of the
send, so omitting it is a compile error, and `engine.keyedHelloHints` goes away.

Advertising a key designator that is not this Host's durable key is refused,
at the same seam and for the same reason: nothing there could sign for it.
`driver_core.Host.setAdvertisedLocator` therefore refuses an unheld key before
retaining the route. A peer cannot advertise an identity it cannot prove.
In-tree keyed transports already unify the endpoint seed with the Host seed
under ADR-0075, so the refusal states an invariant the tree holds and turns a
future drift into a loud failure at the advertising side.

A byte-fed Host on a key-scheme transport also *derives* the designator it
advertises, rather than taking one (`driver_core.sessions.advertisedDesignator`).
There is exactly one legal value, its own durable key, and being told the
designator is how it comes to be something else. A Host that never starts a
listener had nothing to set, so it advertised the unreachable-client
placeholder: a `tcp` address, on a transport whose designator grammar is a key.
That hello is ungrammatical, and its partner could attribute the session to
nobody, which is what a browser member's direct message ran into. Deriving is
what makes the wrong value unrepresentable. Address transports have two honest
states instead: a reachable adapter publishes its complete locator, while a
dial-only Host uses the unreachable-client placeholder. There is no separate
mutable designator beside the advertised-locator registry.

Deriving is available at this tier because a `Host` always holds a durable key,
its node secret, so it always has something true to say. It is not available at
the blocking face, where `driver.Identity.ephemeral` is a caller declining a
durable identity for one dial and drawing a throwaway key. That posture has no
derivable name and correctly signs the placeholder.

### 2. What a lower layer proved, only its realizer may say

`engine.Peer.bindVerifiedChannelKey(key)` is the assertion, and it is made by
supplying the key. ADR-0097 already named this symbol. It did not exist, and the
`DurableKeyBasis` enum stood in for it, which let a caller pick
`.transport_verified` from a name table. The enum goes. A dial installs its
expectation with `demandPartnerDurableKey(key)`, and the code that realized the
connection states, separately, what it verified.

The two are separate because they name different parties. A realizer proves who
holds the far end of the *byte channel*. A dial names the CapTP partner it went
looking for. On a direct dial those are one node. Through a byte-transparent
relay (ADR-0086) they are two, and a session has both facts at once. So
`engine.DurablePin` carries two keys, a `partner` (with the evidence for it) and
a `channel`, and neither can be read as the other. One slot holding whichever
layer spoke last is the failure the Context calls the costliest class in this
core: a name used in a namespace that is not its own.

The relayed browser shows why. A browser dials a
member's `iroh` locator through the relay. The relay dials iroh from its own
endpoint. The native exporter's resident reads the QUIC remote and it is the
*relay's* key. The browser's hello then claims the browser's own key. With one
slot the exporter must either refuse a correct peer or forget what it proved.
With two it does neither: the channel key admits nothing and refuses nothing
here, and the partner's own credential carries its name end to end.

`net.netlayer.AuthenticationMechanism`, its vtable field, and
`driver_core.vocab.authenticationMechanismForTransport` are deleted. A resident
that proves nothing now declares nothing and calls nothing, which is the same
statement made once instead of twice. The realizers are
`net.transport.iroh` (accept today, and dial, which is the missing call),
`net.transport.webrtc`, and `driver.Bridge` through
`net.completion.Loop.verifiedChannelKey`. A byte-fed Host has no realizer in the
library, so what it asserts is whatever the embedder above it testifies through
`Host.bindVerifiedChannelKey`, and a Host whose embedder says nothing asserts
nothing.

A proof and a demand that name different keys are therefore not a contradiction
and do not fail the connection. Both verbs are infallible. What a dial demanded
still governs admission, on its own. What a realizer proved only ever raises
provenance for a claim it matches. A realizer cannot be given standing to refuse
a partner, because it does not know whether it is looking at the partner.

### 3. What this side demands is derived, never configured

`engine.Peer.requirePartnerAttestation` and the `require_partner_attestation`
field are deleted. The demand is computed at the pre-open chokepoint in
`engine.inbound.applyPlainOwnedFrame`, from the claim in front of it and the
evidence the adapter supplied. Let the claim be the hello's
`acceptable_location.designator`, the demand be the key a dial named, and the
channel key be what a realizer verified.

1. A standing demand and a claim that is not a key is
   `PartnerDesignatorMismatch`. This closes the downgrade above.
2. A key claim naming a key other than the demand's is
   `PartnerDesignatorMismatch`.
3. A key claim carrying an attestation hint has it verified, on every
   transport. A hint that fails is `PartnerAttestationInvalid`. A hint that
   verifies records the claimed key as attested.
4. A key claim carrying no attestation is `PartnerAttestationMissing`,
   unless the channel key equals the claim.

Clauses 2 and 4 weigh the claim against two different parties. Only the demand
refuses, because only a demand says who this session meant to talk to. The
channel key only admits a claim it matches. Letting a realizer's key refuse a
differing claim would refuse the relayed browser above.

Clause 3 verifies whenever the credential is present and clause 4 requires it
whenever nothing else proved the name. They are one rule in one function. Only
those two clauses need `verify_partner_handshake`, because a credential binding
a session key nobody authenticated proves nothing. Clauses 1 and 2 weigh one
name against another with no signature in them, so they hold for every peer: an
embedder that waived handshake verification still dialed the identity it dialed.

The block runs only while the session is still waiting for the partner's hello
(`session.Session.awaitsPartnerHello`). A duplicate or post-open
`op:start-session` is refused by `validateStartSession` a few steps later, and
weighing it here would spend a signature verification on a frame already
destined for refusal and let it revise a verdict the accepted hello reached.

### Provenance is derived from the evidence, and the transport string is gone

`durableProvenance` moves from `driver_core.publish` onto the engine as
`engine.Peer.partnerDurableProvenance()`, and it loses its `transport`
parameter, because there is no longer a question a transport string answers.

- A claim that is not a key is `.unauthenticated`.
- A channel key equal to the claim is `.authenticated_transport`.
- An attested partner key equal to the claim is `.durable_key_attestation`.
- Otherwise `.unauthenticated`, reachable only for a peer that verifies no
  handshake.

Every arm answers for the key the claim names and no other. Each fact lives
beside the key it is about, so no consumer can read one of them against a
different name.

A realizer's proof outranks the credential because it also binds the byte channel,
while the credential is static authorization over a record. The order is stated
once, in one function, and `driver_core.vocab.PartnerIdentity.durableIdentityAuthenticated`
keeps its meaning for every caller including `driver_core.enliven.matchSturdyrefPeer`.

Transport proof identifies the
far end of the *byte channel*, and a byte-transparent relay makes that a
different party from the CapTP partner. Requiring the claim to equal the proved
key is what keeps `.authenticated_transport` meaning "my partner is the endpoint
I am encrypted to". A relayed session whose partner proved itself by credential
lands on `.durable_key_attestation` instead, which reports what was proved
and matches the posture section below.

### The ordering constraint dissolves

The hello is minted in `helloAndEnroll` while a transport proof is installed at
connection adoption, so ADR-0097's arrangement required the mint-time decision
to know an adoption-time fact. Neither decision needs it now. The mint reads
only this side's designator and durable key, both known at mint time. The demand
is evaluated when the partner's claim arrives, and every path installs its proof
before the first byte is fed: `connectVia` before `nl.dial` and the resident
during it, `Bridge.makeConnCtx` before `openDialedOver` or
`openAcceptedAdvertisedOver`,
the iroh and WebRTC residents inside accept and connection setup. Moving the
demand to where the claim is, instead of to where the hello is built, is what
removes the constraint rather than working around it.

## Per-session footprint

`engine.Peer` replaces `expected_durable_key: ?PeerKey` plus two bools with one
`DurablePin { partner: ?{ key, demanded, attested }, channel: ?PeerKey }`.

The second key is the cost of the decision: two parties at the far end of one
session are two names, and one 32-byte slot holds one. Measured:
`@sizeOf(engine.Peer)` goes from 1080 to 1112 bytes on a 64-bit build, so
`peer_session_struct_budget_bytes` and the `docs/ladder.md` step 2 row both move
to 1112. The budget is the measured size, so the next field added here is a
build failure. At 500,000 sessions the second key is 16 MiB, against a warmed
per-session ceiling of 2 KiB that `test/engine/footprint_budget_test.zig` still
holds. Nothing here allocates: the keys are fixed-width and live in the struct.

The assertion is a ceiling, unlike the `Conn` slot overhead in
`src/net/completion/loop/state.zig`, which measures a difference between two
sizes on one target. This struct is full of pointers and is smaller on
`wasm32`, so no single number is the measurement everywhere.

`HostSession` gains no field, and `durableProvenance` losing its transport
argument removes an argument from three call sites rather than adding state.

Retained bytes grow on the transports that now carry a credential. A Syrup
session retains its partner's raw signed locator for the connection's life, so
an `iroh` or `webrtc` session retains roughly a hundred more bytes: the 64-byte
signature plus its hint name and framing. That is the class ADR-0097's cost
posture already charged for `keyed-tcp`, extended to two more transports, and it
is charged against the warmed 2 KiB per-session ceiling held by
`test/engine/footprint_budget_test.zig`.

## Wire compatibility and interop

Two hello shapes change, both on key-scheme transports.

First, an `iroh` or `webrtc` hello whose designator is a key now carries a
`session-key-attestation` hint. A `keyed-tcp` or `keyed-relay` hello that
already advertised a key designator is byte-identical to today, because it
already carried one.

Second, a byte-fed Host dialing any key-scheme transport now signs its own
durable key as its designator, with the credential that follows from it, where
before a non-listening Host signed the unreachable-client placeholder. That
reaches `keyed-tcp`, `keyed-relay`, `iroh`, `webrtc`, the rendezvous cold-dial
family, and the browser tier. It is the change the mint-condition section above
argues for: the placeholder was an address on a transport whose grammar is a
key, and a partner could attribute the session to nobody.

A hello that named nothing now names a durable identity and proves it, so the
accepting side reports `.durable_key_attestation` where it used to report
`.unauthenticated`. Nothing refuses the new shape: an accept leg holds no
demand, and clause 3 verifies the credential the hello carries. What a partner
may not do is stay anonymous on a key-scheme transport from a byte-fed Host.
That posture is the blocking face's `Identity.ephemeral`, and the Scope section
records that the Host tier does not offer it.

Goblins implements neither `iroh` nor `webrtc`, and speaks `tcp` with address
designators, so no hello a Goblins peer sees changes shape. The hint remains the
provisional encoding ADR-0097 committed, and
`zig build goblins-gift-hints` already proves a real Goblins peer decodes,
re-encodes, and verifies a signature over the mapping-shaped hint dict. URI and
dial projection already omit the credential, so a give naming an iroh exporter
is unchanged on the wire and the pinned Goblins withdrawal lookup is unaffected.
The upstream OCapN suite runs over `tcp` with address designators and sees no
change.

One tightening reaches every transport. A `tcp` partner that claims a
key designator must now attest it or be refused. Nothing in the tree
does this and Goblins does not. The rule is that whoever claims a durable name
proves it. That universality is what lets
the transport table go.

## Security posture

A relayed key-designator session has `keyed-tcp`'s posture, not iroh's. The
credential proves the durable key authorized this session key, over a static
record with no challenge in it, and the channel is protected only as far as the
carrier. Provenance reports which fact was proved, so an application reading
`.durable_key_attestation` learns exactly that and nothing stronger. What
changes is that the relayed dialer now has a proof at all, and that a dial
naming a durable key can no longer settle for a partner that claims none.

## Required evidence

The byte-fed tier is held by
[`test/driver/core_host/`](../../../test/driver/core_host/). Each item below
names what carries it, or says that nothing does.

1. A peer reached through a relay reports `durable_key_attestation` provenance
   and an authenticated durable identity, on the strength of its credential
   rather than the carrier's key. Held at the engine tier by "a relayed accept
   leg reports the partner its credential proved". The same assertion from a
   real browser tab over a live relay has no coverage.
2. The same dial refuses when the relay substitutes a different node, whether
   that node claims its own key or an address. Held by "a dial through a relay
   still refuses the partner it did not ask for" and "a dial that named an
   identity refuses a partner claiming an address". The live substitution has no
   coverage.
3. A native iroh dial reports `.authenticated_transport`. Held byte-fed against
   a bound remote key in `core_host_test.zig`, and live by
   `zig build goblins-interop`'s iroh driver, which fails the run unless the
   partner reports that provenance. The blocking, owning `HostRuntime`, and
   completion `Bridge` faces are not each asserted separately.
4. A WebRTC leg whose signaling named no peer identity refuses a key-designator
   claim that carries no credential. The engine half is held by "a key-designator
   claim nothing proved is refused before open". The WebRTC answer leg that
   records a signaling-scoped identity is not built.
5. Each keyed transport's per-binding proof asserts provenance. The Python and
   Racket rows of the keyed-TCP restart family do. The Deno and Rust rows of
   that family, and the whole `keyed-relay` rendezvous family, assert none.
6. A peer that advertises a key designator it does not hold the secret for is
   refused at the advertising side. Held by the `UnheldIdentity` refusal in
   `core_host_test.zig` and by "a hello advertising a key the sender cannot sign
   for is refused here".
7. The refusal matrix of ADR-0097 still holds, and the keyed-TCP and keyed-relay
   hello bytes are unchanged. ADR-0109 removed the mutation
   negatives and signing vectors that held it, with the mechanism.


## Scope (what this does not decide)

- **No challenge and no channel binding.** Freshness is unchanged. A captured
  hello replayed on another cleartext or relayed connection still revives its
  own static claim, exactly as ADR-0097 and ADR-0075 state.
- **No new transport symbol for a relayed path.** The transport in a locator
  names the peer's address family. The attestation record, the hello signature,
  locator equality, and the Goblins withdrawal lookup all bind that exact
  string, so renaming it at the dialer would break four things to describe one.
- **No policy knob.** There is no option to require or waive authentication. The
  demand is derived, because a knob is how the hole reopens.
- **A peer behind a relay can still claim the relay's own key.** Clause 4 admits
  a credential-free claim that equals the channel key, and under a relay the
  channel key is the carrier's. So any peer the relay carries can advertise the
  relay's durable name and be reported `.authenticated_transport`. Closing it
  means dropping clause 4's escape and requiring a credential universally, which
  is a separate wire decision about peers that prove by transport and mint
  nothing. The exposure is unchanged from before this record. It is named here
  because the two-key split is what makes it possible to state.
- **A byte-fed Host has one durable identity and every key-scheme dial
  advertises it.** There is no anonymous posture at this tier. Declining a
  durable identity for one dial is `driver.Identity.ephemeral` at the blocking
  face, which draws a throwaway key and signs the placeholder.
- **`designatorSchemeForTransport` stays.** Locator grammar is a property of
  the transport symbol. Only the mechanism was not.
- **WebRTC's DTLS fingerprint attestation is still adapter work.**
  `authorizeRemote` remains the signaling capability's scope rather than a
  sidecar proof. What changes is that its absence no longer silently reads as a
  transport proof.
- **No change to handoff descriptor shapes, signature domains, gift registry
  authority, or sturdyref matching** beyond the provenance derivation
  `matchSturdyrefPeer` already reads.
- **Durable registry persistence across restart remains unimplemented**
  (ADR-0098's boundary).

## Alternatives Considered

- **Pass a mechanism into the Host at session open.** Rejected: it keeps one
  authority for two independent facts, the mint and the demand, and it puts the
  adapter's word in place of the adapter's evidence. An adapter that can prove
  something should supply the proof, and one that cannot should supply nothing.
- **Mint the credential only when the adapter says the transport will not prove
  the name.** Rejected: it is the current design with the table moved one layer
  up. The minting side cannot know whether the *dialing* side has a resident,
  and that asymmetry is the defect.
- **Give the relayed path its own transport symbol.** Rejected above: the
  transport string is the peer's, and four separate contracts bind it.
- **Report `.authenticated_transport` whenever a resident realized the
  connection, without the claim-equality clause.** Rejected: under a relay the
  proved endpoint is the carrier, so the provenance would name the wrong party.
- **Recompute provenance on demand from the retained locator instead of
  recording a bit.** Rejected: it costs an Ed25519 verification per query on a
  path the live trace reads per session, and it makes the retained bytes a
  second authority for a verdict the chokepoint already reached.
- **Leave the address-claim downgrade open and report it through provenance.**
  Rejected: a dial named an identity, and every consumer would have to remember
  to check.
- **One key in the pin, with a flag saying which layer put it there.** Rejected.
  It survives only while a dial and a realizer agree, which a relay breaks: the
  accepting side must then forget what QUIC proved or refuse a partner whose
  credential is good.
- **Keep the placeholder designator for a non-listening Host.** Rejected: it
  carries a `tcp` address on a transport whose designator grammar is a key, so
  the partner has nothing to attribute the session to. Deriving the one legal
  value makes the wrong one unrepresentable.

## Consequences

- `driver_core.vocab` loses `AuthenticationMechanism` and
  `authenticationMechanismForTransport`. `net.netlayer` loses the mirror enum
  and its vtable field. `source-check` loses their sync check and gains a
  call-site check.
- `engine.Peer` loses `DurableKeyBasis`, `requirePartnerAttestation`, and
  `require_partner_attestation`, and gains `DurablePin`,
  `demandPartnerDurableKey`, `bindVerifiedChannelKey`,
  `recordAttestedDurableKey`, the two read accessors `demandedPartnerKey` and
  `verifiedChannelKey`, and `partnerDurableProvenance`. Three verbs write the
  pin and nothing else names it. `source-check` holds both halves
  (`checkDurablePinWriters`), and `checkHostErrorCodeMap` keeps a new
  `HostError` member from reaching a C embedder as `GLOWCAP_ERR_INTERNAL`.
- `engine.partnerAttestationVerifies` answers with an optional
  `VerifiedAttestation` rather than a bool, so the key a credential proved and
  the fact that it was checked travel together and
  `recordAttestedDurableKey` cannot be handed a key nobody verified.
- No new engine error. The pin's writers are infallible, because the two facts
  they record are about two parties and cannot contradict each other.
- `driver_core.publish.durableProvenance` becomes a thin alias over the engine
  derivation, and its three call sites drop the transport argument. One of them
  is `Host.partnerIdentity`, which the live trace reads, so the trace reports the
  same verdict every other consumer does.
- Every keyed hello on `iroh` and `webrtc` gains a credential, and every
  key-designator claim anywhere must carry one unless a realizer proved it.
- A key-designator dial becomes a demand rather than a preference: the partner
  claims the named identity and proves it, or the session does not open.
- `docs/boundaries.md` states the connection rule, including the relayed
  session's replay posture, instead of listing authentication by transport.
- `glowcap_iroh_conn_remote_node_id` hands a connection's QUIC-verified endpoint
  id to whoever opened it, accepted or dialed.
  `glowcap_host_session_bind_verified_channel_key` is the C entry point for
  `engine.Peer.bindVerifiedChannelKey`, refused once the partner's handshake has
  been applied. Each binding's iroh accept and dial paths call it themselves.
  `libglowcap_net_transport_iroh` does not link `libglowcap_host`, because the
  relay dials iroh as a byte pipe with no CapTP host.

## Notes

- ADR-0097 owns fresh session keys, the credential's record shape and signing
  domain, and the two-signature chain. All of that stands. This record replaces
  its per-transport mechanism assignment with a per-connection one.
- ADR-0086's byte-transparency property is unchanged. This record states its
  consequence for verification: a transport proof names the far end of the byte
  channel, so an end-to-end proof has to ride the hello.
- ADR-0089's posture is unchanged, including that DTLS secures the pipe while
  the keyed handshake proves identity. The credential is what a peer without a
  WebRTC resident can check.
- ADR-0075, ADR-0090, ADR-0076, and ADR-0070 supply the driver faces and the
  browser tier whose divergence this record removes.
- ADR-0098 continues to own sturdyref peer authority and reads provenance
  through `durableIdentityAuthenticated`, whose meaning is unchanged.
