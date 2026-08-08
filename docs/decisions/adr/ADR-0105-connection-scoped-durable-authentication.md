---
id: ADR-0105
status: accepted
date: 2026-08-04
tags: [captp, handshake, identity, transport, relay, iroh, webrtc, keyed-tcp]
decision: "Durable authentication is a property of the realized connection, not its transport name. A matching authenticated-channel key supplies positive provenance; a dial target is only a requirement. ADR-0109 retires the durable-key hint credential, so claims without channel proof remain unauthenticated."
supersedes: []
superseded_by: []
amends: [ADR-0097]
amended_by: [ADR-0109]
---

# ADR-0105 Connection-scoped durable authentication

## Status

Accepted for the rule that authentication belongs to the realized connection.
ADR-0109 removes the durable-key credential branch. Current provenance is
either matching authenticated-channel proof or unauthenticated. The partner's
verified session key, its signed locator claim, and channel provenance are
separate facts. A dial's expected key constrains the acceptable claim but does
not authenticate it. ADR-0109 limits that comparison to a selected
key-designator route; a selected address route describes independent ingress.

The Context through Notes below preserve the design and rollout as adopted.
Present-tense references there to `session-key-attestation`, credentials,
attested partner keys, or `.durable_key_attestation` are historical and do not
describe current pancake behavior.

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

Four more instances of the same shape are live in the tree, which is what makes
this a class rather than a browser bug.

- The blocking face derives the pin basis from the resident's declaration
  (`driver.blocking_session.connectVia` reading `nl.authentication()`), while the
  owning `driver.PollHost` face installs only `.dial_expectation` and the iroh
  resident's own `residentDial` never upgrades it. The same iroh dial to the same
  node reports `.authenticated_transport` through one driver face and
  `.unauthenticated` through another.
- A WebRTC leg whose signaling owner named no peer identity leaves
  `webrtc.Peer.authorized_remote` null, so `webrtc.Peer.connection` installs no
  binding. The transport table still says `authenticated_transport`, so no
  credential is demanded either, and the session opens with nothing proved and
  nothing said.
- A binding-hosted iroh listener has an end-to-end QUIC connection and no way to
  say so. The C ABI exports no seam for a verified remote key, and
  `pancake_iroh_netlayer_try_accept` surfaces no remote node id, so every
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
`driver_core.Host.setSelfDesignator` refuses it too, so a caller that sets an
unheld designator learns at the setter rather than on some later dial. A peer
cannot advertise an identity it cannot prove. In-tree keyed transports already unify the endpoint seed with the
Host seed under ADR-0075, so the refusal states an invariant the tree holds and
turns a future drift into a loud failure at the advertising side.

A byte-fed Host on a key-scheme transport also *derives* the designator it
advertises, rather than taking one (`driver_core.sessions.advertisedDesignator`).
There is exactly one legal value, its own durable key, and being told the
designator is how it comes to be something else. A Host that never starts a
listener had nothing to set, so it advertised the unreachable-client
placeholder: a `tcp` address, on a transport whose designator grammar is a key.
That hello is ungrammatical, and its partner could attribute the session to
nobody, which is what a browser member's direct message ran into. Deriving is
what makes the wrong value unrepresentable. The address arm is unchanged; a
bound address or the placeholder is genuinely the answer there.

Deriving is available at this tier because a `Host` always holds a durable key,
its node secret, so it always has something true to say. It is not available at
the blocking face, where `driver.Identity.ephemeral` is a caller declining a
durable identity for one dial and drawing a throwaway key. That posture has no
derivable name and correctly signs the placeholder.

This is a wire change, and the section on wire compatibility below states its
extent rather than leaving it to be discovered.

### 2. What a lower layer proved, only its realizer may say

`engine.Peer.bindVerifiedChannelKey(key)` is the assertion, and it is made by
supplying the key. ADR-0097 already named this symbol; it did not exist, and the
`DurableKeyBasis` enum stood in for it, which let a caller pick
`.transport_verified` from a name table. The enum goes. A dial installs its
expectation with `demandPartnerDurableKey(key)`, and the code that realized the
connection states, separately, what it verified.

**Separately, because the two name different parties.** A realizer proves who
holds the far end of the *byte channel*. A dial names the CapTP partner it went
looking for. On a direct dial those are one node; through a byte-transparent
relay (ADR-0086) they are two, and a session has both facts at once. So
`engine.DurablePin` carries two keys, a `partner` (with the evidence for it) and
a `channel`, and neither can be read as the other. One slot holding whichever
layer spoke last is the failure this record's own Context calls the costliest
class in this core: a name used in a namespace that is not its own.

It matters immediately, on the path this record exists to fix. A browser dials a
member's `iroh` locator through the relay; the relay dials iroh from its own
endpoint; the native exporter's resident reads the QUIC remote and it is the
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
still governs admission, on its own; what a realizer proved only ever raises
provenance for a claim it matches. A realizer cannot be given standing to refuse
a partner, because it does not know whether it is looking at the partner.

### 3. What this side demands is derived, never configured

`engine.Peer.requirePartnerAttestation` and the `require_partner_attestation`
field are deleted. The demand is computed at the pre-open chokepoint in
`engine.inbound.applyDecodedOwnedFrame`, from the claim in front of it and the
evidence the adapter supplied. Let the claim be the hello's
`acceptable_location.designator`, the demand be the key a dial named, and the
channel key be what a realizer verified.

1. A standing demand and a claim that is not a key is
   `PartnerDesignatorMismatch`. This closes the downgrade above.
2. A key claim naming a key other than the demand's is
   `PartnerDesignatorMismatch`.
3. A key claim carrying an attestation hint has it verified, on every
   transport. A hint that fails is `PartnerAttestationInvalid`; a hint that
   verifies records the claimed key as attested.
4. A key claim carrying no attestation is `PartnerAttestationMissing`,
   unless the channel key equals the claim.

Clauses 2 and 4 weigh the claim against two different parties, deliberately.
Only the demand refuses, because only a demand says who this session meant to
talk to; the channel key only ever admits a claim it matches. Reversing that —
letting a realizer's key refuse a differing claim — is what refused the relayed
browser above.

Clause 3 verifies whenever the credential is present and clause 4 requires it
whenever nothing else proved the name. Those are one rule with two clauses, in
one function, so belt and braces do not become two authorities. Only those two
clauses need `verify_partner_handshake`, because a credential binding a session
key nobody authenticated proves nothing. Clauses 1 and 2 weigh one name against
another with no signature in them, so they hold for every peer: an embedder
that waived handshake verification still dialed the identity it dialed.

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

Every arm answers for the key the claim names and no other, which is what makes
the `designator` argument load-bearing throughout rather than in one arm. Each
fact lives beside the key it is about, so no consumer can read one of them
against a different name.

A realizer's proof outranks the credential because it also binds the byte channel,
while the credential is static authorization over a record. The order is stated
once, in one function, and `driver_core.vocab.PartnerIdentity.durableIdentityAuthenticated`
keeps its meaning for every caller including `driver_core.enliven.matchSturdyrefPeer`.

The equality clause matters more than it looks. Transport proof identifies the
far end of the *byte channel*, and a byte-transparent relay makes that a
different party from the CapTP partner. Requiring the claim to equal the proved
key is what keeps `.authenticated_transport` meaning "my partner is the endpoint
I am encrypted to". A relayed session whose partner proved itself by credential
lands on `.durable_key_attestation` instead, which is the honest report of what
was proved, and matches the posture section below.

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

That is not byte-neutral, and the second key is the cost of the decision rather
than an overrun. Two parties at the far end of one session are two names, and
one 32-byte slot can hold only one of them. Measured: `@sizeOf(engine.Peer)`
goes from 1080 to 1112 bytes on a 64-bit build, so
`peer_session_struct_budget_bytes` and the `docs/ladder.md` step 2 row both move
to 1112 — the measured size, so the next field added here is a build failure
rather than a withdrawal nobody watches. At 500,000 sessions the second key is
16 MiB, against a warmed per-session ceiling of 2 KiB that
`test/engine/footprint_budget_test.zig` still holds. Nothing here allocates: the
keys are fixed-width and live in the struct.

The assertion stays a ceiling rather than an equality, unlike the `Conn` slot
overhead in `src/net/completion/loop.zig`. That one measures a difference
between two sizes on one target; this one measures a struct full of pointers,
and `wasm32` makes it genuinely smaller, so no single number is the measurement
everywhere.

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

Its consequence for a partner is the good direction. A hello that named nothing
now names a durable identity and proves it, so the accepting side reports
`.durable_key_attestation` where it used to report `.unauthenticated`. Nothing
refuses the new shape: an accept leg holds no demand, and clause 3 verifies the
credential the hello carries. What a partner may not do is stay anonymous on a
key-scheme transport from a byte-fed Host; that posture is the blocking face's
`Identity.ephemeral`, and the Scope section records that the Host tier does not
offer it.

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
does this and Goblins does not, and refusing it is the honest reading of the
rule: whoever claims a durable name proves it. That universality is what lets
the transport table go.

## Security posture, stated plainly

A relayed key-designator session has `keyed-tcp`'s posture, not iroh's. The
credential proves the durable key authorized this session key, over a static
record with no challenge in it, and the channel is protected only as far as the
carrier. Provenance reports which fact was proved, so an application reading
`.durable_key_attestation` learns exactly that and nothing stronger. What
changes is that the relayed dialer now has a proof at all, and that a dial
naming a durable key can no longer settle for a partner that claims none.

`docs/boundaries.md` currently says a relayed browser handshake "still
authenticates the peers end to end" and lists mechanisms by transport. Both
sentences become true under this decision instead of aspirational, and the
transport list is replaced by the connection rule.

## Required evidence

Before ADR-0109 retired the credential branch, the four-clause rule and both
evidence verbs were held by its attestation contract test,
and the byte-fed tier by
[`test/driver/core_host_test.zig`](../../../test/driver/core_host_test.zig).
Each item below names what carries it, or says plainly that nothing does yet.

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
   partner reports that provenance. The blocking, owning `PollHost`, and
   completion `Bridge` faces are not each asserted separately.
4. A WebRTC leg whose signaling named no peer identity refuses a key-designator
   claim that carries no credential. The engine half is held by "a key-designator
   claim nothing proved is refused before open"; the WebRTC answer leg that
   records a signaling-scoped identity is migration step 6 and is not built.
5. Each keyed transport's per-binding proof asserts provenance. The Python and
   Racket rows of the keyed-TCP restart family do. The Deno and Rust rows of
   that family, and the whole `keyed-relay` rendezvous family, assert none.
6. A peer that advertises a key designator it does not hold the secret for is
   refused at the advertising side. Held by the `UnheldIdentity` refusal in
   `core_host_test.zig` and by "a hello advertising a key the sender cannot sign
   for is refused here".
7. The refusal matrix of ADR-0097 still holds, and the keyed-TCP and keyed-relay
   hello bytes are unchanged. Held by the mutation negatives in
   the former attestation contract test and committed signing vectors. ADR-0109
   removed that evidence with the mechanism.

## Migration standing

Steps 1 through 3 and step 7 have landed, so the decision governs the tree: the
transport table is gone, the pin carries two keys, the chokepoint derives the
demand, and `meta-check` holds the pin's writers. This record is accepted on
that basis, which is what the decisions README asks for before code is built
against a record.

Steps 4 through 6 have not landed. Step 7 landing ahead of the evidence step is
out of order, and this record says so rather than reading as if the plan were
followed: the `meta-check` swap and the `docs/boundaries.md` rewrite are in,
while the live browser relay probe, the live substituted-node negative, the
missing per-binding provenance assertions, and the WebRTC answer leg are not.
Required evidence items 1 through 5 above say which half of each is covered.

Step 5 has landed. `pancake_iroh_conn_remote_node_id` hands a connection's
QUIC-verified endpoint id to whoever opened it, on an accepted connection as on
a dialed one, and `pancake_host_session_bind_verified_channel_key` is where that
proof reaches a session: the C entry point for `engine.Peer.bindVerifiedChannelKey`,
refused once the partner's handshake has been applied. The Goblins netlayer in
`conformance/goblins-peer/racket/iroh-netlayer.rkt` weighs the id itself, and
`zig build goblins-iroh` holds the accepting side reporting
`authenticated-transport` and naming the endpoint that called it.

Each binding's own iroh accept and dial paths now testify without being asked,
so an application that calls the binding's `listen`/`connect` gets the fact for
free and never names this verb. That is what closes the gap the step was
written for: a binding hosting its own pancake iroh listener reported only what
its partner's credential proved, while a stronger fact sat one call away in the
transport archive it had already linked.

The archives stay symbol-disjoint through it. `libpancake_net_transport_iroh`
still does not link `libpancake_host`, because the relay dials iroh as a byte
pipe with no CapTP host at all; a transport that called into the host would take
the session pointer from the same caller that holds the connection, which is the
composition the embedder was already doing.

## Migration order

Each step is green on its own gate before the next begins.

1. **Mint everywhere.** The mint moves into `engine.Peer.sendKeyedStartSession`
   and conditions on durable-key possession; `engine.keyedHelloHints` goes away,
   and `helloAndEnroll` and the blocking connect and accept paths stop
   assembling credentials of their own. Add the refusal to advertise an unheld
   key designator, and derive the advertised designator on a key-scheme
   transport (`driver_core.sessions.advertisedDesignator`). The credential is
   additive on the wire; the derivation is not, and the wire section above is
   where its extent is stated. Gate: `zig build test`, then `zig build check`,
   then `zig build iroh-interop`, `webrtc-interop`, `bindings-relay-iroh`,
   `check-external`.
2. **Realizers assert.** Add `engine.Peer.bindVerifiedChannelKey` and delete
   `DurableKeyBasis`. `net.transport.iroh.residentDial` reads the connection's
   remote node id and asserts it. `connectVia` stops deriving a basis from
   `nl.authentication()`. Delete `net.netlayer.AuthenticationMechanism`, its
   vtable field, and `vocab.authenticationMechanismForTransport`. Gate:
   `zig build meta-check`, `zig build test`, `iroh-interop`, `iroh-loop`,
   `webrtc-interop`, `tcp-loop`.
3. **Derive the demand.** Replace the pin fields with `DurablePin`'s two keys,
   record the credential verdict on the partner half, implement the four-clause
   chokepoint rule, delete `requirePartnerAttestation`, and move provenance onto
   the engine. Gate: `zig build test`, `zig build oracle-check`,
   `zig build check`, then `check-external`, the relay family, and
   `rooms-web-dm`.
4. **Evidence for the uncovered path.** Assert provenance in the browser-over-relay
   iroh probe and add the substituted-node negative. Add the missing provenance
   assertions to the `keyed-relay` rendezvous proofs and to the Deno and Rust
   rows of the keyed-TCP restart family. Gate: `zig build bindings-relay-iroh`,
   `bindings-keyed-relay-rendezvous`, `bindings-keyed-tcp-restart`,
   `rooms-web-dm`.
5. **The C ABI seam.** Landed as
   `pancake_host_session_bind_verified_channel_key`, the C entry point for
   `engine.Peer.bindVerifiedChannelKey`, over `Host.bindVerifiedChannelKey`. It
   is refused once the partner's handshake has been applied, so it needs no new
   per-session flag, and it takes the key as a locator writes it so the one
   decoder stays where designator rules live. Surface the remote node id on the
   iroh transport archive so a binding-hosted listener can call it; each
   binding's iroh accept and dial paths then do so themselves. Gate: `zig build gen-header-host`,
   `gen-header-net-transport-iroh`, `gen-ts-abi`, the `gen-binding-*` family,
   `zig build bindings`, `deno-iroh-loop`, `bindings-iroh-handoff`.
6. **WebRTC answer leg.** Record the signaling-scoped identity on the answer leg
   where the signaling owner names one, so both legs report the fact they hold.
   Gate: `zig build webrtc-interop`, `webrtc-signaling-captp`,
   `rooms-web-dm-webrtc`.
7. **Scaffolding and docs.** Replace `meta-check`'s
   `checkAuthenticationMechanismSync` with `checkDurablePinWriters`: the two
   evidence verbs are callable only from the layer that holds each fact, and the
   pin's own field name appears only in the file that declares it, so a direct
   write or a rival derivation is refused rather than merely discouraged. Add
   `checkHostErrorCodeMap`, so a new `HostError` member cannot reach a C
   embedder as `PANCAKE_ERR_INTERNAL` by falling through two `else` arms. Add
   the transport-symbol row to the Names table in
   `tools/check/meta_check/namespaces.zig` recording that a transport string does
   not name an authentication mechanism. Update `docs/boundaries.md`,
   `docs/architecture.md`, and `docs/shipped.md`. Gate: `zig build meta-check`,
   `zig build check`.

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
  nothing. The exposure is unchanged from before this record; it is named here
  because the two-key split is what makes it possible to state.
- **A byte-fed Host has one durable identity and every key-scheme dial
  advertises it.** There is no anonymous posture at this tier. Declining a
  durable identity for one dial is `driver.Identity.ephemeral` at the blocking
  face, which draws a throwaway key and signs the placeholder.
- **`designatorSchemeForTransport` stays.** Locator grammar genuinely is a
  property of the transport symbol. Only the mechanism was the impostor.
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
  Rejected: a dial named an identity. Opening a session to a peer that claims
  none and reporting it quietly is the same defect one layer further out, and
  every consumer would have to remember to check.
- **One key in the pin, with a flag saying which layer put it there.** Rejected,
  and it is the design this record shipped first. It survives only while a dial
  and a realizer always agree, which is exactly the assumption a relay breaks:
  the accepting side then has to choose between forgetting what QUIC proved and
  refusing a partner whose credential is perfectly good. Policing the collision
  instead of adding the dimension is the move `AGENTS.md`'s Names rule says has
  had to be taken back every time.
- **Keep the placeholder designator for a non-listening Host.** Rejected: it
  carries a `tcp` address on a transport whose designator grammar is a key, so
  the partner has nothing to attribute the session to, which is the defect a
  browser member's direct message reported. Deriving the one legal value costs
  the caller nothing to say and makes the wrong one unrepresentable.

## Adversarial review

Four lenses were run over the plan. Each attacked it, and each changed it.

**Wire clarity** attacked the claim that minting on `iroh` is harmless, and
demanded the interop consequence be named rather than assumed. It also refused
the first draft's "verify if present, require if nothing proved" as two rules
that could drift apart. Three changes followed. The rule became four numbered
clauses in one function with a stated precedence. The wire section now names
exactly which hellos change bytes and which do not, and cites
`goblins-gift-hints` as the live decode evidence rather than asserting Goblins
tolerance. The tightening on `tcp` key-shaped claims is stated as a deliberate
universal rule instead of being left as an accident of deleting the table.

**Stability steward** attacked the evidence list. Its objection was that a
design fixing an uncovered path must not ship with that path still uncovered,
and that a per-binding proof family with one row missing its assertions is a
tier claimed on partial evidence. Required evidence item 1 now names the
uncovered path explicitly. Item 2 adds the substituted-node negative, so the
positive cannot pass on a coincidence. Migration step 4 exists solely to close
the `keyed-relay` rendezvous family's silence and the TypeScript keyed-TCP row's
missing assertions. It also forced the security posture section: a
relayed session's provenance means `keyed-tcp`'s guarantee, and saying so is
cheaper than a consumer discovering it.

**Fresh eyes** attacked the vocabulary. "Authentication mechanism", "durable
key basis", and "provenance" were three names for overlapping things, and a
reader could not tell which one an adapter was supposed to set. The decision is
now organized as three numbered facts with an owner each. The enum with a
member any caller could pick is replaced by a verb only a realizer would reach
for. The reason the transport name cannot be renamed moved into the Context,
where a newcomer meets it, rather than staying buried in Alternatives.

**Scaffolding rigor** attacked the plan for deleting a `meta-check` member
without replacing it, which would leave a real invariant with nothing holding
it. Migration step 7 now replaces `checkAuthenticationMechanismSync` with a
check that `bindVerifiedChannelKey` appears only in connection-realizing code,
and adds the transport-symbol row to the Names table. The layering rule this ADR
argues in prose is then held by the gate rather than by memory.

The strongest objection came from wire clarity and it stands answered in the
design rather than in prose: two mechanisms proving one fact is a second
authority unless one function computes one verdict in a stated order. That is
why provenance moved onto the engine, lost its transport parameter, and became
the single ordered derivation the chokepoint and the report both read.

## Consequences

- `driver_core.vocab` loses `AuthenticationMechanism` and
  `authenticationMechanismForTransport`; `net.netlayer` loses the mirror enum
  and its vtable field; `meta-check` loses their sync check and gains a
  call-site check.
- `engine.Peer` loses `DurableKeyBasis`, `requirePartnerAttestation`, and
  `require_partner_attestation`, and gains `DurablePin`,
  `demandPartnerDurableKey`, `bindVerifiedChannelKey`,
  `recordAttestedDurableKey`, the two read accessors `demandedPartnerKey` and
  `verifiedChannelKey`, and `partnerDurableProvenance`. Three verbs write the
  pin and nothing else names it; `meta-check` holds both halves.
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
- `docs/boundaries.md` stops listing authentication by transport and states the
  connection rule, including the relayed session's replay posture.

## Notes

- ADR-0097 owns fresh session keys, the credential's record shape and signing
  domain, and the two-signature chain. All of that stands; this record replaces
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
