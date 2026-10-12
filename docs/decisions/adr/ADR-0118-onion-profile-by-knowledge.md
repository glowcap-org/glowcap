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

> **Shipped state.** The mechanism ships across the Host tiers and the blocking
> and completion dial tiers. Knowledge mints from the handed form on every dial
> path (`Peer.dialedLocatorIdentifiesGlowcap`), the profile-configured onion
> accept defers and mirrors, and gives carry the recipient-usable location form.
> The completion bridge retains the complete locator until Host adoption, and
> the hinted-hello probe rides `zig build goblins-onion`. The operator surface
> that mints the hinted address form is open, as Scope names.

## Context

ADR-0108 made every onion locator hintless, including the hello's
`acceptable_location`, so the engine forces the baseline profile on onion. Two
glowcap peers over Tor therefore settle the `1.0` Syrup baseline even though
both ship `glowcap-next` and the Cap'n Proto codec. The multi-profile Host
(`test/driver/core_host/trace_test.zig`, the mixed three-vat matrix) exists to
speak each partner's best language on one host. Onion is canonical Goblins
ground, so a glowcap pair there is likely to stand next to a Goblins vat, and
the glowcap pair pays the compatibility cost even with no Goblins peer near
the session.

### What the pinned Goblins constrains

ADR-0108's blanket rule closes over two narrower pinned facts.

**The hello is hint-tolerant on every transport.** The pinned `captp.rkt`
inbound `op:start-session` arm matches any `ocapn-node`, verifies the signature
over the claimed location bytes hints and all, and stores the node verbatim. The
location-mismatch check is commented out and the dial-back is unfinished
upstream. Two live checks observe this: `zig build goblins-gift-hints` (a hinted
hello on tcp, keyed hints and all, through a full three-party handoff), and the
hinted-hello probe inside `zig build goblins-onion`, where a real vat over real
circuits accepts a hello whose signed onion location carries the `glowcap/*`
profile hints, ignores them, settles the baseline, and answers an echo call.

**The dial is refused.** Goblins' `onion.rkt` `connect-to` matches only
`(ocapn-node 'onion designator #f)`, so a hinted onion locator falls through
and the dial fails. The withdrawal lookup (`locations->open-session-names`) is
`equal?`-keyed over the whole node, so a `desc:handoff-give` redeems only when
its exporter locator equals the exporter's hello as the receiver saw it.

Together these force one rule: an onion location that a Goblins peer may need
to dial (a give's exporter location, a future dial-back) must be bare, and the
withdrawal keying makes the hello the receiver sees part of the same equation.
The hello itself is not constrained.

## Decision

State the preference where the partner is known, and hand every other party
the bare form. The one behavior change for a peer that never asked for an
upgrade, the accept side's deferred hello, is gated on the existing opt-in: a
configured non-baseline CapTP version or codec (`Session.statesUpgradedProfile`).
Features are the full ignorable set by default and opt nothing in. A
default-profile host answers an onion accept eagerly and bare, as ADR-0108
specifies, and `test/driver/core_host/locator_test.zig` pins that alongside the
deferred case. Knowledge is recorded wherever the handed form carries it, since
a baseline hello stamps nothing and the give path needs to know a recipient is
glowcap. No feature flag exists, because a flag would only track this same
configuration act.

- **Dial side.** A glowcap operator's onion address has two forms of one
  designator: the bare canonical form, the only form glowcap puts on the wire,
  and a hinted form carrying the ordinary `glowcap/*` profile hints, minted for
  out-of-band distribution between glowcap parties. A dialer handed the hinted
  form knows its acceptor is glowcap before any hello (`Host.openDialedLocator`
  mints the knowledge, `Peer.noteKnownGlowcapPartner` records it), so its hello
  states the configured preference. A dialer holding the bare form states the
  baseline. The onion resident ignores locator hints at dial, and the
  designator alone routes the circuit.
- **Accept side.** On onion alone, a profile-configured acceptor defers its
  hello until the initiator's arrives (`sessions.zig` `acceptedHelloAndEnroll`).
  Only that hello can say whether the partner is glowcap, and because
  `negotiation.settle` intersects both hellos, an acceptor that stated the
  baseline blind would cap the session at the baseline whatever the dialer
  knew. An inbound hello stating a non-baseline preference proves the initiator
  is glowcap (the pinned Goblins onion netlayer signs only bare locations), so
  the answering hello mirrors with the configured preference
  (`Peer.answerDeferredHello`, driven from the Host's before-serve hook). A bare
  inbound hello gets a bare answer, which keeps the exporter-side withdrawal
  equation below consistent for Goblins receivers.
- **Give locations.** A give embeds the exporter's hello location in the form
  its recipient can use (the Node's gifter recipe over
  `handoff_gifter.exporterLocationForRecipient`). The rewrite is onion-only: on
  every other transport the exporter's hello is hinted toward everyone alike,
  so the verbatim bytes already match the receiver's hints-and-all withdrawal
  keying (`goblins-gift-hints` observes this live), and a give sheds no byte.
  On onion, a recipient known to be glowcap (`Session.partnerKnownGlowcap`:
  minted knowledge, or any non-baseline stated preference) keeps the
  exporter's verbatim bytes, profile hints included, and can upgrade its redeem
  session from them. Every other recipient gets the same bytes with the three
  `glowcap/*` entries stripped. Routing hints such as `direct-addresses` pass
  through. The stripped give dials (fact two) and matches the bare hello a
  deferred onion exporter answers an unknown recipient with (the withdrawal
  keying). A Goblins exporter's bytes carry no `glowcap/*` name and take the
  verbatim path.

`engine.advertisedPreference` holds the hello decision in one place: it takes
what is known about the partner beside the transport. Advertised-locator
completion happens at configuration time on every transport. Onion's stored
snapshot is bare, and the one session allowed to state an onion preference
stamps at session time (`Peer.sendKeyedStartSessionAdvertised`).

## Scope (what this does not decide)

- No wire operation, hint name, or negotiation rule changes. `settle` still
  intersects the two signed hellos.
- The hinted URI form is an operator surface. How each product front mints
  or distributes it (CLI flag, rooms directory) is a separate change.
- Hinted onion sturdyrefs are not minted, per ADR-0108: a sturdyref travels as
  a value and can reach a Goblins peer, which cannot dial the hinted form.

## Consequences

Two glowcap peers over Tor settle `glowcap-next` and Cap'n Proto whenever the
dialer was handed the glowcap form, and a glowcap recipient of a three-party
handoff whose exporter runs hinted keeps that upgrade on the redeem session.
Every byte a Goblins peer must act on is unchanged: it receives no hinted onion
locator it would have to dial, its withdrawal keying sees a give equal to the
hello it was shown, and the one hinted onion hello it can receive, from a
misapplied hinted dial, is accepted and ignored, as the probe observes live.
The deferred acceptor hello is observable as ordering only. An initiator that
never says hello never hears one on onion, and times out on the budgets that
bound a silent partner.

## Evidence

- Hermetic: `test/driver/onion_host_test.zig` ("onion profile by
  knowledge"): over the fake Tor daemon, a hinted dial settles
  `glowcap-next`/Cap'n Proto and carries a call, and a bare dial between the
  same two peers settles the baseline. `test/driver/core_host/locator_test.zig`
  pins the deferred accept (no hello frame before the initiator's) and the
  hintless stored advertisement.
- Live: the hinted-hello probe inside `zig build goblins-onion` (the vat
  accepts a glowcap-hinted onion hello, settles the baseline, answers the
  echo), with `zig build goblins-onion` and `zig build
  ocapn-conformance-onion` otherwise unchanged.
