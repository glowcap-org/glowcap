---
id: ADR-0119
status: superseded
date: 2026-08-17
tags: [locators, netlayer, negotiation, handoff, glowcap-next, upstream]
decision: "Multi-homing is prototyped as a measured comparison of two shapes on one shared core: a keyed id/via locator skin expanded through the Node pending-dial waist and gated by glowcap-next route-vocabulary negotiation, and a multi-location locator vocabulary gated as a named glowcap-next negotiated feature. No new CapTP version is minted, no baseline byte changes, and the success criterion is upstream adoption of whichever shape the measurements favor."
supersedes: []
superseded_by: [ADR-0125]
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

Rooms needs transport-stable room links and directory peering: one directory
should be able to hand out a room hosted elsewhere without choosing one
transport for every future reader. A browser peer may ride the relay while
native peers speak iroh, tcp, or onion, and any pair without a shared transport
cannot hold a direct line. Listener administration has the same coupling:
`listen` unconditionally selects the new listener as the Host's signed
location, so bringing a second listener up silently moves the peer's advertised
identity. ADR-0108 and ADR-0118 spent a design cycle on which single onion
location a hello or a give may carry, because a location is identity today.

The upstream community has discussed this direction repeatedly and has not
implemented it:

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
  an identity layer would encode multiple netlayers beneath one straddling
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
is the shape as a network property: its routes are its own, no other OCapN
implementation can join, browsers cannot run it, and a sturdyref welded to it
bets long-lived identity on one ecosystem.

glowcap already holds every ingredient of the netlayer shape: four keyed
transports, the sealed channel of
[ADR-0107](ADR-0107-sealed-byte-channel.md) proving a durable key over any
byte carrier, relay carriers, and the hint machinery of
[ADR-0118](ADR-0118-onion-profile-by-knowledge.md). Choosing between the two
shapes by argument alone would waste that position. Identity must have one
owner.

## Decision

Prototype both shapes on one shared core and let measurements choose what
goes upstream. The shared core is plain library code: the route-bundle data
shape, ordered fallback scheduling, and key verification through transports
that can prove a durable key. Full dial racing is not part of this record. The
core is expressed through two skins:

- **A keyed id transport symbol.** The designator is a durable public key.
  Routes are carried in the `via` hint. The prototype admits only carriers that
  prove the same durable key as the outer id, so it claims no identity through a
  route whose key binding is unspecified. An optional
  `alt-locators` list carries weak handoff fallbacks: the signed gift authorizes
  that withdrawal, but the fallback neither establishes nor caches the outer
  identity and a sturdyref never dials it. An independently authenticated
  channel may still prove the outer key. No baseline CapTP byte changes. `id`
  is never opened as a physical session. The Node pending-dial waist expands it
  to a concrete route, and a peer that did not negotiate this vocabulary sees
  a concrete compatible route or a refusal.
- **A multi-location locator vocabulary variant.** A named negotiated
  feature under `glowcap-next`, stamped into the signed hello and refused
  unless both peers advertise it, the same machinery the pairing suite pins
  today. The feature name and its documentation carry comparison-only
  status, because no recorded upstream proposal specifies this shape. It exists
  to be measured against the netlayer shape. It is not a same-peer proof and
  adds no dial paths. Toward a baseline peer or
  Goblins, no novel byte leaves the machine.

The compatibility floor is per session, not per host. A host may prefer
`glowcap-next`, Cap'n Proto, and every linked transport for other glowcap
hosts, while the same process keeps a Goblins session on `1.0` over Syrup.
Hello emission follows that settled session. A signed give crosses two settled
sessions, so its exporter location lies in their intersection: the recipient
must be able to dial it, and the exporter must admit its locator vocabulary when
the signed give returns inside the withdrawal. If the exporter session did not
negotiate route vocabulary, a configured baseline locator remains valid, while
a configured `id` or multi-location locator falls back to the concrete location
the exporter claimed on that session. A peer that negotiated
`multi_location` may receive the `glowcap/locations` vocabulary as
comparison-only data. A peer that did not gets a single baseline locator for a
transport it demonstrably participates in: the transport carrying its current
session. Baseline CapTP advertises no remote outbound-provider inventory, so the
gifter does not invent one. If no matching route exists, lowering refuses. The
fallback is never to serialize glowcap-next vocabulary and hope the recipient
ignores it. `id` follows the same rule at the identity layer: a recipient
without route-vocabulary negotiation is handed one concrete route or no route
at all, never an instruction to parse `via`.

No new CapTP version is minted. A version symbol gates wholesale where the
comparison needs per-shape dials in one binary, and it is the most expensive
namespace in the system. The feature stamp is finer and cheaper. Both skins
land on trunk behind the gates above, held by `zig build check`.

Each skin must produce the same measurement: the enumerated diff of what it
forced us to touch (records, session tables, checks, conformance scenarios,
binding surfaces), plus the compatibility checks that keep baseline peers from
seeing experimental vocabulary. The comparison is evidence the maintainer must
independently understand before writing any policy-compliant upstream proposal,
and the repository artifact is not forwarded (see the
[community-review](../../community-review.md) preflight). Upstream adoption of a
multi-home shape is the success criterion. The prototypes remain product
features (cross-transport rooms) regardless of the upstream outcome.

## Scope (what this does not decide)

- No winner is chosen here. That is what the measurements are for.
- The `1.0` profile, the Goblins-facing wire, and every existing transport
  symbol are unchanged. Nothing here amends ADR-0108 or ADR-0118.
- The id's `via` hint schema is not final. It is a prototype surface whose
  interop cost is one of the measurements.
- Rooms composes its active key-proving listeners under `via`, keeps baseline
  listeners under `alt-locators`, and publishes durable rooms between
  directories through that route. Listener selection remains deployment
  policy owned above the core.
- Session-intersection route lowering is present at the signed-give boundary:
  a baseline exporter replaces private route vocabulary with its concrete
  session location, an unknown recipient gets one concrete route instead of
  `id`, and private route
  vocabulary is stripped from baseline locators. A discovered identity route
  becomes future give advice only after the corresponding withdrawal resolves
  to a capability. Rooms directory peering is the product consumer.
- Host-level `id` sturdyref enlivenment is present for the prototype: an opted-in
  Host selects an active authenticated same-key session, including a baseline
  session because no route syntax crosses that established channel, or stages
  the concrete `via` routes through the Node pending-dial waist. Host parking
  and Node dial publication commit atomically. `glowcap/locations` sturdyrefs
  remain comparison-only and are refused because the hint does not prove peer
  identity.
- Whether the sealed channel's Noise pattern converges with issue 208's
  eventual spec text stays a condition tracked in
  [`docs/upstream-watch.md`](../../upstream-watch.md), not a promise here.

## Alternatives Considered

- **Mint a `glowcap-experimental` CapTP version**: rejected. A version gates
  at session granularity where the comparison needs per-feature dials, and
  the symbol would carry development status, not a wire-level meaning.
- **Choose the netlayer shape by argument and skip the comparison**:
  rejected. The vocabulary shape's true cost is an empirical claim, and the
  measured enumeration is the persuasive upstream artifact.
- **Extend the core locator vocabulary only**: rejected as the sole path. It
  begs the identity question and changes bytes every implementation must
  parse, so it enters only as the measured counter-proposal.
- **Feature branches for both prototypes**: rejected. Branch code is code no
  gate holds.
- **Wait for upstream to specify multi-homing**: rejected. Upstream has
  deferred the direction, influence is cheapest before text exists, and the
  prototypes are wanted product features either way.

## Consequences

- The model owns route-bundle parsing and limits. Session owns `id`
  admission policy, and Node redeem uses that shared policy before staging a
  dial. A future provider archive or route-key binding must keep using that
  spine rather than parsing its own route list or deciding key proof locally.
- A registered `glowcap-next` feature name for the vocabulary variant, with
  refusal-before-send toward non-advertising peers pinned beside the
  existing negotiation scenarios in `test/engine/pairing/`.
- Scenarios per skin, and baseline-unchanged proofs: the Goblins interop steps
  stay green, and a first hello toward a baseline peer does not carry the
  experimental route vocabulary with either prototype linked.
- The measurement lands as a declared planning document naming what each
  skin touched, and feeds the community-review preflight before the maintainer
  independently writes any policy-compliant upstream proposal. The repository
  artifact itself is not posted upstream.
- `docs/upstream-watch.md` and `docs/boundaries.md` gain the present-tense
  boundary lines in the same changes that land each skin.

## Evidence and gate

The pairing suite already pins the gating machinery this record leans on:
features advertise into the signed hello, fallback retains the baseline profile,
and an unstamped non-baseline profile is refused before it is sent. Each skin
lands with its own scenarios under that suite and the transport test tree, and
`zig build check` holds both behind the same aggregate as every other landed
slice. The compatibility claim is narrow: existing live interop steps keep
running unchanged against a build with both prototypes present, while focused
tests pin first-hello silence, signed-give lowering, Host-level `id` sturdyref
staging, and fail-closed `glowcap/locations` sturdyrefs. The recurring Rooms
server suite pins profile-gated Noise/TCP route advertisement and TCP directory
peering. When the iroh sidecar is available, an additional scenario publishes a
room from an iroh identity route into a destination without iroh and redeems it
through the weak TCP fallback.

## Forward compatibility

If upstream adopts either shape, the surviving skin's names converge on the
spec text and the other skin is deleted. The
convergence conditions for the sealed channel (handshake pattern, prologue,
locator shape) are the ones `docs/upstream-watch.md` already names for
issue 208. If upstream mints a transport-agnostic vat id, the id
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
