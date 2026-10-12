---
id: ADR-0103
status: accepted
date: 2026-08-03
tags: [codec, session, engine, driver, handshake, interop]
decision: "Every `op:start-session` is the baseline, in both its grammar and its version field, whatever the session goes on to speak. A peer states its preferred profile in the locator hint dict instead, including version, codec, and feature set. Both sides settle the pair with the symmetric `engine.negotiation.negotiate` they already share, and the session switches at the handshake boundary. A host's configured profile is what it prefers. The session owns what was decided, and an axis the two cannot agree on stays at the v1.0 Syrup baseline."
supersedes: []
superseded_by: []
amends: [ADR-0003]
amended_by: []
---

# ADR-0103 Hello-carried profile offers

## Status

Accepted and implemented. It closes the hint-carried offer boundary ADR-0003
names. The settle path is
`model.Preference`, `engine.negotiation.settle`, and
`engine.Peer.settleNegotiatedProfile`. `test/driver/core_host/trace_test.zig` holds
one host on two profiles at once.

## Context

`driver_core.Host.Options` carries one `captp_version`, one `codec`, and one
`features`. These are preferences: `sessions.negotiatingOptions` stamps them
onto every session at mint, dialed and accepted alike, and the handshake
settles the active tuple with the partner. If the tuple were fixed host
configuration, a host that preferred `glowcap-next` over Cap'n Proto could not
also hold a v1.0 Syrup session with a Goblins vat. It would refuse that vat: a
mismatched version is `CaptpVersionMismatch` at `session/validate.zig`, and a
mismatched codec fails earlier because the frame does not parse.

A profile is what a peer prefers, and what two peers speak is a property of the
pair. `engine.negotiation.negotiate` settles that from two offers,
symmetrically across version, codec, and features. A peer on a socket needs a
way to learn the other's offer, which the hello-carried preference provides.

Session state is authoritative: the decided profile belongs to the session, and
configuration is what the host brings to the decision.

The pinned Goblins peer decides the two constraints. A vat aborts on any
`captp-version` string but its own (`ocapn/captp.rkt`, the `^setup-completer`
match), so a hello that advertises a version by naming it is refused by every peer
that does not already know that version. And the locator inside a hello carries
a `hints` dict that Goblins round-trips byte-exactly, which `zig build
goblins-gift-hints` already proves live against a real vat.

## Decision

Every `op:start-session` is encoded in Syrup, whatever codec the session goes on
to speak. A peer never has to guess, sniff, or be told out of band what codec a
greeting arrived in, because the answer is the one every OCapN implementation
speaks.

The hello's version field is the baseline too: the pinned Goblins source aborts
the session on any `captp-version` string but its own, so a peer that stated its
preference there would refuse every partner that did not already share it.
`sendKeyedStartSession` therefore takes no version at all.

What travels instead is one `model.Preference` (one version, one codec, and one
feature set) in the hints of the locator the hello carries: the sender's
`acceptable_location`, the signed record saying where it can be reached. The
preference sits beside `direct-addresses` there, under
`model.transport.hint_captp_version`, `hint_codec`, and `hint_features`, and
both peers state theirs symmetrically. Duplicate preference hint names are
malformed because the signed hint dict is authoritative. A malformed
`hint_features` value is refused.

The locator a dialer was handed plays no part. A dial URI may carry the same
hints and nothing reads them: the handshake is the baseline whatever the dialer
knew, and the settle runs off the two hellos. This works when a peer is handed
a bare `host:port` with no hints, and needs no configuration, discovery, or
agreement arranged in advance.

Only the preference travels, not the accepted set: a glowcap peer speaks the
baseline, so what it accepts is derivable from what it prefers. A hello that
carries none of the preference hints says "the baseline", as an implementation
that does not know these names does. The baseline feature set names behavior
proven against Goblins and therefore excludes outbound `op:untag`, even though
1.0 inbound support remains mandatory. Two Glowcap peers advertise the
additional `untag` bit without inventing another wire version. A
compatibility-default peer signs the same bytes as a peer that does not know
these names.

`session.Session` records both sides' claims and `engine.negotiation.settle`
decides with them when the partner's hello lands, falling back to the baseline
on any axis the two cannot agree on. The session keeps what it asked for beside what it got, so
"why is this session on the baseline" is answerable.

`driver_core.Host.Options` therefore describes what a host prefers. This adds
no configuration and no C ABI surface.

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
  are distinguishable. Rejected because it makes every peer's parser depend on a property of the
  encodings that no protocol text states, and a third codec whose framing
  collided with either would break it silently.
- **Advertise the preferred version in the hello's version field and let the
  partner refuse down.** Rejected on the Goblins evidence above: a vat aborts
  the session rather than answering with what it does support, so this reaches
  no peer that does not already agree.
- **Keep the profile as host configuration and require both ends to be
  configured alike.** Rejected because it makes an ordinary mixed room
  impossible: a glowcap fleet cannot admit one Goblins member without dropping
  every session to the baseline.
- **Add an offer field to `op:start-session`.** Rejected because glowcap does
  not add fields to OCapN's messages, and the hint dict is the protocol's
  extension point.

## Consequences

A room can hold a Goblins member and a glowcap member at once, each on the
profile its pair settled, as `apps/ocapnviz/src/fixtures/three-vat-handoff-mixed.ts`
depicts.

Two frames per session are encoded and decoded in Syrup that a Cap'n Proto pair
would otherwise have encoded in Cap'n Proto. That is once per session, off every
per-turn path, and lets a peer parse any greeting.

A glowcap-to-glowcap handshake carries the preference hints, and the handshake
bytes in the oracle corpus record them.
