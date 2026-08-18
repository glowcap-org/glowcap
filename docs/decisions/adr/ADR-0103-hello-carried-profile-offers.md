---
id: ADR-0103
status: accepted
date: 2026-08-03
tags: [codec, session, engine, driver, handshake, interop]
decision: "Every `op:start-session` is the baseline, in both its grammar and its version field, whatever the session goes on to speak. A peer states its preferred profile in the locator hint dict instead, including version, codec, and feature set; both sides settle the pair with the symmetric `engine.negotiation.negotiate` they already share, and the session switches at the handshake boundary. A host's configured profile is what it prefers; the session owns what was decided, and an axis the two cannot agree on stays at the v1.0 Syrup baseline."
supersedes: []
superseded_by: []
amends: [ADR-0003]
amended_by: []
---

# ADR-0103 Hello-carried profile offers

## Status

Accepted and implemented. ADR-0003 named hint-carried offers across the network
as its present boundary; this closes it. The settle path is
`model.Preference`, `engine.negotiation.settle`, and
`engine.Peer.settleNegotiatedProfile`; `test/driver/core_host/trace_test.zig` holds
one host on two profiles at once.

## Context

Before this ADR, a host's CapTP version, codec, and feature set were
configuration, and every session it held wore the same tuple.
`driver_core.Host.Options` now still carries one `captp_version`, one `codec`,
and one `features`, but those are preferences: `sessions.negotiatingOptions`
stamps them onto every session at mint, dialed and accepted alike, and the
handshake settles the active tuple with the partner. The old shape meant a host
that preferred `pancake-next` over Cap'n Proto could not also hold a v1.0 Syrup
session with a Goblins vat. It refused that vat: a mismatched version was
`CaptpVersionMismatch` at `session/validate.zig`, and a mismatched codec never
got that far, because the frame did not parse.

That is the wrong shape for the thing pancake is. A profile is what a peer
_prefers_, and what two peers actually speak is a property of the pair, not of
either one. `engine.negotiation.negotiate` has settled exactly that from two
offers since ADR-0003, symmetrically across version, codec, and features.
Before this ADR, nothing on a socket called it; only the in-process
`engine.pairing` did, because a peer on a socket had no way to learn the
other's offer. The Status section names the live settle path that closed that
gap.

This engages the first principle that session state is authoritative. The
decided profile is session state and belongs to the session. Configuration is
what the host brings to the decision.

The pinned Goblins peer decides the two constraints. A vat aborts on any
`captp-version` string but its own (`ocapn/captp.rkt`, the `^setup-completer`
match), so a hello that advertises a version by naming it refuses every peer
that does not already know that version. And the locator inside a hello carries
a `hints` dict that Goblins round-trips byte-exactly, which `zig build
goblins-gift-hints` already proves live against a real vat.

## Decision

Every `op:start-session` is encoded in Syrup, whatever codec the session goes on
to speak. That single sentence removes the problem that forced every alternative
here: a peer never has to guess, sniff, or be told out of band what codec a
greeting arrived in, because there is only one answer and it is the one every
OCapN implementation already speaks.

The hello's version field is the baseline too, for the same reason one step
further: the pinned Goblins source aborts the session on any `captp-version`
string but its own, so a peer that stated its preference there would refuse
every partner that did not already share it. `sendKeyedStartSession` therefore
takes no version at all.

What travels instead is one `model.Preference` — one version, one codec, and
one feature set — in the hints of the locator the hello already carries: the
sender's own `acceptable_location`, the signed record saying where it can be
reached. The preference sits beside `direct-addresses` there, under
`model.transport.hint_captp_version`, `hint_codec`, and `hint_features`, and
both peers state theirs symmetrically. Duplicate preference hint names are
malformed because the signed hint dict is authoritative; a malformed
`hint_features` value is likewise refused rather than silently read as the
baseline.

That is deliberately not the locator a dialer was handed. A dial URI may carry
the same hints and nothing reads them, because it does not need to: the
handshake is the baseline whatever the dialer knew, and the settle runs off the
two hellos. So this works when a peer is handed a bare `host:port` with no
hints at all, which is the case that matters — it needs no configuration, no
discovery, and no agreement arranged in advance.

Only the preference, never the accepted set: a pancake peer speaks the baseline
by construction, so what it accepts is derivable from what it prefers. A hello
that carries none of the preference hints has said "the baseline", which is
exactly what an implementation that never heard of these names is saying. The
baseline feature set names behavior proven against Goblins and therefore
excludes outbound `op:untag`, even though 1.0 inbound support remains mandatory.
Two Pancake peers advertise the additional `untag` bit without inventing
another wire version. A compatibility-default peer still signs the
byte-identical hello it always did.

`session.Session` records both sides' claims and `engine.negotiation.settle`
decides with them when the partner's hello lands, falling back to the baseline
on any axis the two cannot agree on. The session keeps what it asked for beside
what it got, because "why is this session on the baseline" is a question worth
being able to answer.

`driver_core.Host.Options` therefore describes what a host _prefers_. This adds
no configuration and no C ABI surface: the accepted set was never a knob.

## Scope (what this does not decide)

- Discovery-carried offers, where a peer learns a partner's profile before
  dialing from something other than the locator it was handed, are not
  implemented.
- Renegotiating a live session's profile is not implemented. The pair is
  settled once, at the handshake boundary, and holds for the session.
- A third codec or feature is not introduced. The offer's codec axis ranges
  over the registered codecs, the feature axis ranges over `model.FeatureSet`,
  and nothing here changes either set.

## Alternatives Considered

- **Detect the greeting's codec from its first bytes.** Syrup frames open with
  a grammar marker and Cap'n Proto frames open with a segment count, so the two
  are distinguishable. Rejected because it makes every peer's parser depend on a
  property of the encodings rather than on anything the protocol states, and a
  third codec whose framing collided with either would break it silently. The
  offer belongs in the message, where a reader can see it.
- **Advertise the preferred version in the hello's version field and let the
  partner refuse down.** Rejected on the Goblins evidence above: a vat aborts
  the session rather than answering with what it does support, so this reaches
  no peer that does not already agree.
- **Keep the profile as host configuration and require both ends to be
  configured alike.** This is the present shape. Rejected because it makes an
  ordinary mixed room impossible: a pancake fleet cannot admit one Goblins
  member without dropping every session to the baseline.
- **Add an offer field to `op:start-session`.** Rejected because pancake does
  not add fields to OCapN's messages, and the hint dict is the extension point
  the protocol already carries for exactly this.

## Consequences

A room can hold a Goblins member and a pancake member at once, each on the
profile its pair settled, which is what `apps/ocapnviz/src/fixtures/three-vat-handoff-mixed.ts`
depicts and what nothing in the tree could do before.

Two frames per session are encoded and decoded in Syrup that a Cap'n Proto pair
would otherwise have encoded in Cap'n Proto. That is once per session, off every
per-turn path, and it is what buys a peer the ability to parse any greeting.

A pancake-to-pancake session's handshake changes shape on the wire, so the
handshake bytes in the oracle corpus move with it. pancake ships under no
compatibility promise, so this is a re-record, not a migration.
