---
id: ADR-0118
status: accepted
date: 2026-08-17
tags: [onion, negotiation, hello, handoff, goblins]
decision: "Over onion, a peer states its real profile preference exactly when it knows its partner is glowcap: a dialer knows from the hinted form of the address it was handed, an acceptor knows by deferring its hello and mirroring an inbound glowcap-hinted one. A give embeds the exporter location in the form its recipient can use: verbatim for a known-glowcap recipient, profile hints stripped for everyone else. Every other wire-carried onion locator stays bare."
supersedes: []
superseded_by: []
amends: [ADR-0108]
amended_by: []
---

# ADR-0118 Onion profile by knowledge

> **Landing note.** The mechanism ships across the Host tiers and the
> blocking and completion dial tiers: knowledge mints from the handed form on every dial
> path (`Peer.dialedLocatorIdentifiesGlowcap`), the profile-configured onion
> accept defers and mirrors, and gives carry the recipient-usable location
> form. The completion bridge retains the complete locator until Host
> adoption, and the hinted-hello probe rides `zig build goblins-onion`.
> Still open, named in Scope: the operator surface that mints the hinted
> address form.

## Context

ADR-0108 made every onion locator hintless, including the hello's
`acceptable_location`, and the engine forced the baseline profile on onion as
a consequence. The cost has grown with the product: two glowcap peers over Tor
settle the `1.0` Syrup baseline even though both ship `glowcap-next` and the
Cap'n Proto codec, and the multi-profile Host
(`test/driver/core_host/trace_test.zig`, the mixed three-vat matrix) exists
precisely to speak each partner's best language on one host. Onion is
canonical Goblins ground, which makes it exactly the transport where a
glowcap pair is most likely to stand next to a Goblins vat — and the glowcap
pair paid the whole compatibility bill even with no Goblins peer anywhere
near the session.

### What the pinned Goblins actually constrains

ADR-0108's blanket rule was a conservative closure over two narrower pinned
facts, and the distinction is what this ADR is built on.

**The hello is hint-tolerant, on every transport.** The pinned `captp.rkt`
inbound `op:start-session` arm matches any `ocapn-node`, verifies the
signature over the claimed location bytes hints-and-all, and stores the node
verbatim; the location-mismatch check is commented out and the dial-back is
left unfinished upstream. This is observed live twice: `zig build
goblins-gift-hints` (a hinted
hello on tcp, keyed hints-and-all through a full three-party handoff), and
the hinted-hello probe inside `zig build goblins-onion`, where a real vat
over real circuits accepts a hello whose signed **onion** location carries
the `glowcap/*` profile hints, ignores them, settles the baseline, and
answers an echo call.

**What is actually pinned as refusal is the dial.** Goblins'
`onion.rkt` `connect-to` matches only `(ocapn-node 'onion designator #f)`; a
hinted onion locator falls through and the dial fails outright. And the
withdrawal lookup (`locations->open-session-names`) is `equal?`-keyed over
the whole node, so a `desc:handoff-give` redeems only when its exporter
locator equals the exporter's hello as **the receiver** saw it.

Chained together, the two facts force one rule: an onion location that a
Goblins peer may need to dial — a give's exporter location, a future
dial-back — must be bare, and the withdrawal keying makes the hello the
receiver sees part of that same equation. The hello itself was never the
constraint.

## Decision

State the preference exactly where the partner is known, and hand every
other party the bare form. The one behavior change for a peer that never
asked for an upgrade — the accept side's deferred hello — is gated on the
one opt-in that already exists: a configured non-baseline CapTP version or
codec (`Session.statesUpgradedProfile`; features are the full ignorable set
by default and opt nothing in). A default-profile host answers an onion
accept eagerly and bare, exactly as ADR-0108 left it, and
`test/driver/core_host/locator_test.zig` pins that alongside the deferred
case. Knowledge itself is recorded unconditionally wherever the handed form
carries it, because a baseline hello stamps nothing regardless and the give
path still wants to know a recipient is glowcap. There is no separate
feature flag, because a flag would only ever track this same configuration
act.

- **Dial side.** A glowcap operator's onion address has two spellings of one
  designator: the bare canonical form, the only form glowcap ever puts on
  the wire, and a hinted form carrying the ordinary `glowcap/*` profile
  hints, minted for out-of-band distribution between glowcap parties. A
  dialer handed the hinted form knows its acceptor is glowcap before any
  hello (`Host.openDialedLocator` mints the knowledge;
  `Peer.noteKnownGlowcapPartner` records it), so its hello states the
  configured preference. A dialer holding the bare form states the baseline,
  exactly as before. The onion resident ignores locator hints at dial rather
  than refusing them; the designator alone routes the circuit.
- **Accept side.** On onion alone, a profile-configured acceptor defers its hello until the
  initiator's arrives (`sessions.zig` `acceptedHelloAndEnroll`), because
  only that hello can say whether the partner is glowcap — and because
  `negotiation.settle` intersects both hellos, an acceptor that stated the
  baseline blind would cap the session at the baseline no matter what the
  dialer knew. An inbound hello stating a non-baseline preference is proof
  the initiator is glowcap — the pinned Goblins onion netlayer signs only
  bare locations — so the answering hello mirrors with the configured
  preference (`Peer.answerDeferredHello`, driven from the Host's
  before-serve hook). A bare inbound hello gets a bare answer, which is
  also what keeps the exporter-side withdrawal equation below consistent
  for Goblins receivers.
- **Give locations.** A give embeds the exporter's hello location in the
  form its recipient can use (the Node's gifter recipe over
  `handoff_gifter.exporterLocationForRecipient`), and the rewrite is
  onion-only: on every other transport the exporter's hello is hinted
  toward everyone alike, so the verbatim bytes already match the receiver's
  hints-and-all withdrawal keying (`goblins-gift-hints` observes this
  live), and a give must not shed a byte. On onion, a recipient known to
  be glowcap (`Session.partnerKnownGlowcap`: minted knowledge, or any
  non-baseline stated preference) keeps the exporter's verbatim bytes,
  profile hints and all, and can upgrade its redeem session from them.
  Every other recipient gets the same bytes with exactly the three
  `glowcap/*` entries stripped; routing hints such as `direct-addresses`
  ride through untouched. The stripped give both dials (fact two) and
  matches the bare hello a deferred onion exporter answers an unknown
  recipient with (the withdrawal keying), while a Goblins exporter's bytes
  never carry a `glowcap/*` name and always take the verbatim path.

`engine.advertisedPreference` keeps the hello decision in one place: it takes
what is known about the partner beside the transport, instead of the
transport alone. Advertised-locator completion stays at configuration time
on every transport; onion's stored snapshot stays bare, and the one session
allowed to state an onion preference stamps at session time
(`Peer.sendKeyedStartSessionAdvertised`).

## Scope (what this does not decide)

- No wire operation, hint name, or negotiation rule changes; `settle` still
  intersects the two signed hellos.
- The hinted URI form is an operator surface. How each product front mints
  or distributes it (CLI flag, rooms directory) is its own change.
- Hinted onion **sturdyrefs** stay unminted, as ADR-0108 left them: a
  sturdyref travels as a value and can reach a Goblins peer, which cannot
  dial the hinted form.

## Consequences

Two glowcap peers over Tor settle `glowcap-next` and Cap'n Proto whenever
the dialer was handed the glowcap form, and a glowcap recipient of a
three-party handoff whose exporter runs hinted keeps that upgrade on the
redeem session. Every byte a Goblins peer must act on is unchanged: it never
receives a hinted onion locator it would have to dial, its withdrawal keying
sees a give equal to the hello it was shown, and the one hinted onion hello
it can ever receive — from a deliberately misapplied hinted dial — is
accepted and ignored, which the probe observes live rather than assumes.
The deferred acceptor hello is observable as ordering only; an initiator
that never says hello never hears one on onion, and times out on the same
budgets that already bound a silent partner.

## Evidence

- Hermetic: `test/driver/onion_host_test.zig` ("onion profile by
  knowledge") — over the fake Tor daemon, a hinted dial settles
  `glowcap-next`/Cap'n Proto and carries a call, and a bare dial between the
  same two peers settles the baseline. `test/driver/core_host/locator_test.zig`
  pins the deferred accept (no hello frame before the initiator's) and the
  hintless stored advertisement.
- Live: the hinted-hello probe inside `zig build goblins-onion` (the vat
  accepts a glowcap-hinted onion hello, settles the baseline, answers the
  echo), with `zig build goblins-onion` and `zig build
  ocapn-conformance-onion` otherwise unchanged.
