---
id: ADR-0119
status: proposed
date: 2026-08-17
tags: [locators, netlayer, negotiation, handoff, pancake-next, upstream]
decision: "Multi-homing is prototyped as a measured comparison of two shapes on one shared core: a keyed meta-netlayer transport symbol gated by linking, and a multi-location locator vocabulary gated as a named pancake-next negotiated feature. No new CapTP version is minted, no baseline byte changes, and the success criterion is upstream adoption of whichever shape the measurements favor."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0119 Multi-home comparison protocol

## Context

A peer reachable over several transports has no way to say so. The pinned
draft defines a peer as one transport plus one designator: the
[Locators draft](../../../conformance/ocapn-spec/upstream/draft-specifications/Locators.md)
compares peers by "the designator and transport" alone, the
[Netlayers draft](../../../conformance/ocapn-spec/upstream/draft-specifications/Netlayers.md)
requires that "the designator and transport alone MUST be enough to
differenciate between two locations, hints are not used for that", and a
[third-party handoff](<../../../conformance/ocapn-spec/upstream/draft-specifications/CapTP Specification.md>)
carries exactly one `exporter-location`. Under the current vocabulary, one
program on two netlayers is two peers, and a sturdyref binds object identity
to one of them.

This cost is not hypothetical in this tree. Rooms needs cross-transport
reach: a browser peer rides the relay while native peers speak iroh, tcp, or
onion, and any pair without a shared transport cannot hold a direct line.
The listener-administration work surfaced the same coupling one layer down:
`listen` unconditionally selects the new listener as the Host's signed
location, so bringing a second listener up would silently move the peer's
advertised identity, and the registry has to hand selection back by hand.
ADR-0108 and ADR-0118 spent a full design cycle on which single onion
location a hello or a give may carry, precisely because a location is
identity today.

The upstream community has discussed this direction repeatedly and wants it,
unimplemented:

- [2021-09-24](../../../conformance/ocapn-spec/upstream/meeting-minutes/2021-09-24.md):
  the `ocapn:` URI carries a netlayer slot because "having multiple
  netlayers is expected".
- [2023-09-12](../../../conformance/ocapn-spec/upstream/meeting-minutes/2023-09-12.md):
  Spritely is "interested in" locators that specify multiple netlayers at
  once, and has not implemented them.
- [2024-02-13](../../../conformance/ocapn-spec/upstream/meeting-minutes/2024-02-13.md):
  the vat id should separate from the swissnum and become a transport-agnostic
  public key, with "transport-agnostic crypto, and parallel connection
  attempts that race and one wins".
- [2024-05-14](../../../conformance/ocapn-spec/upstream/meeting-minutes/2024-05-14.md):
  a "meta-netlayer" would encode multiple netlayers beneath one straddling
  key, with its own encryption layer, and "would come later".
- [2025-07-08](../../../conformance/ocapn-spec/upstream/meeting-minutes/2025-07-08.md):
  relays are first-class at Agoric today, and Spritely is working toward an
  end-to-end encrypted relay netlayer, proposed as
  [OCapN issue 208](https://github.com/ocapn/ocapn/issues/208) and tracked in
  [`docs/upstream-watch.md`](../../upstream-watch.md).

Two shapes fall out of that record. The vocabulary shape extends the locator
and handoff records to carry several locations, which forces the identity
question (when are two homes the same peer?) and changes bytes every
implementation must at least parse, because handoffs relay locators through
third parties. The netlayer shape answers the identity question first: the
designator is a durable key, routes live in hints (which the draft already
excludes from identity), and an end-to-end channel proves the key over
whichever carrier wins. The [architecture rule](../../../.agents/rules/architecture.md)
already notes that iroh implements this shape privately: a key-named node,
relay-assisted and direct routes raced under the hood. What iroh cannot give
is the shape as a network property rather than a dependency: its routes are
its own, no other OCapN implementation can join, browsers cannot run it, and
a sturdyref welded to it bets long-lived identity on one ecosystem.

pancake holds every ingredient of the netlayer shape already: four keyed
transports, the sealed channel of
[ADR-0107](ADR-0107-sealed-byte-channel.md) proving a durable key over any
byte carrier, relay carriers, and the hint machinery of
[ADR-0118](ADR-0118-onion-profile-by-knowledge.md). Choosing between the two
shapes by argument alone would waste that position. The engaged principles
are protocol evidence over folklore, one authority per fact (identity must
have one owner), and conformance as the load-bearing surface.

## Decision

Prototype both shapes on one shared core and let measurements choose what
goes upstream. The shared core is plain library code with no gating
question: the route-bundle data shape, the racing dial, and key verification
through the sealed channel. It is expressed through two skins:

- **A keyed meta-netlayer transport symbol.** Its own provider archive,
  linked or absent like every transport, so it costs nothing when unbuilt.
  The designator is a durable public key; routes are a standardized hint
  schema inside that one netlayer's spec surface; the sealed channel proves
  the designator end-to-end regardless of carrier. No CapTP vocabulary
  changes; any profile can ride it; a peer that does not ship it degrades
  per-link exactly as a peer without onion does today.
- **A multi-location locator vocabulary variant.** A named negotiated
  feature under `pancake-next`, stamped into the signed hello and refused
  unless both peers advertise it, the same machinery the pairing suite pins
  today. The feature name and its documentation carry comparison-only
  status, because no recorded upstream proposal specifies this shape; it
  exists to be measured against the netlayer shape. Toward a baseline peer
  or Goblins, no novel byte leaves the machine.

No new CapTP version is minted. A version symbol gates wholesale where the
comparison needs per-shape dials in one binary, and it is the most expensive
namespace in the system; the feature stamp is the finer and cheaper gate.
No feature branches: both skins land on trunk behind the gates above, held
by `zig build check`, because branch code is code no gate is holding.

Each skin must produce the same measurement: the enumerated diff of what it
forced us to touch (records, session tables, checks, conformance scenarios,
binding surfaces), and live evidence that a baseline peer meeting a
multi-homed peer is uneventful. The comparison, not either proposal, is the
artifact taken upstream through the
[community-review](../../community-review.md) preflight. Upstream adoption
of a multi-home shape is the success criterion; the prototypes remain
product features (cross-transport rooms) regardless of the upstream outcome.

## Scope (what this does not decide)

- No winner is chosen here; that is what the measurements are for.
- The `1.0` profile, the Goblins-facing wire, and every existing transport
  symbol are unchanged; nothing here amends ADR-0108 or ADR-0118.
- The meta-netlayer's hint schema is not final; it is a prototype surface
  whose interop cost is one of the measurements.
- Runtime multi-listener behavior in rooms and the Host location-selection
  seam are named evidence, not deliverables of this record.
- Whether the sealed channel's Noise pattern converges with issue 208's
  eventual spec text stays a condition tracked in
  [`docs/upstream-watch.md`](../../upstream-watch.md), not a promise here.

## Alternatives Considered

- **Mint a `pancake-experimental` CapTP version**: rejected; a version gates
  at session granularity where the comparison needs per-feature dials, and
  the symbol would carry development status, not a wire-level meaning.
- **Choose the netlayer shape by argument and skip the comparison**:
  rejected; the vocabulary shape's true cost is an empirical claim, and the
  measured enumeration is the persuasive upstream artifact.
- **Extend the core locator vocabulary only**: rejected as the sole path; it
  begs the identity question and changes bytes every implementation must
  parse, so it enters only as the measured counter-proposal.
- **Feature branches for both prototypes**: rejected; long-lived branches
  rot against the integration stream and hide work from the gates.
- **Wait for upstream to specify multi-homing**: rejected; the direction is
  explicitly deferred upstream, influence is cheapest before text exists,
  and the prototypes are wanted product features either way.

## Consequences

- A new provider archive and layer entry for the meta-netlayer symbol, with
  its realization policy owned by the archive per ADR-0112's provider seam.
- A registered `pancake-next` feature name for the vocabulary variant, with
  refusal-before-send toward non-advertising peers pinned beside the
  existing negotiation scenarios in `test/engine/pairing/`.
- Conformance scenarios per skin, and baseline-unchanged proofs: the
  Goblins interop steps stay green, and a hello toward a baseline peer stays
  byte-identical with either prototype linked.
- The measurement lands as a declared planning document naming what each
  skin touched, and feeds the community-review preflight before anything is
  posted upstream.
- `docs/upstream-watch.md` and `docs/boundaries.md` gain the present-tense
  boundary lines in the same changes that land each skin.

## Evidence and gate

The pairing suite already pins the gating machinery this record leans on:
features advertise into the signed hello, fallback retains the baseline
profile, and an unstamped non-baseline profile is refused before it is sent.
Each skin lands with its own scenarios under that suite and the transport
test tree, and `zig build check` holds both behind the same aggregate as
every other landed slice. The upstream-facing claim (a baseline peer meets a
multi-homed peer uneventfully) is proven by the existing live interop steps
running unchanged against a build with both prototypes present.

## Forward compatibility

If upstream adopts either shape, the surviving skin's names converge on the
spec text and the other skin is deleted rather than maintained; the
convergence conditions for the sealed channel (handshake pattern, prologue,
locator shape) are the ones `docs/upstream-watch.md` already names for
issue 208. If upstream mints a transport-agnostic vat id, the meta-netlayer
designator is positioned to become that id's carrier without a second
migration, which is the reason identity lives in the designator and not in
the hint schema.

## Notes

Related records: [ADR-0055](ADR-0055-iroh-netlayer-sidecar.md) (iroh as the
demonstration of the keyed shape), [ADR-0107](ADR-0107-sealed-byte-channel.md)
(the carrier-agnostic key proof), [ADR-0108](ADR-0108-onion-netlayer.md)
and [ADR-0118](ADR-0118-onion-profile-by-knowledge.md) (what single-location
identity costs on canonical Goblins ground), ADR-0112 (the provider seam new
transports enter through).
