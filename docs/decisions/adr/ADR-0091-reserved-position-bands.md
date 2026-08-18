---
id: ADR-0091
status: accepted
date: 2026-08-02
tags: [model, position, handoff, session, naming]
decision: "Wire positions and locally synthesized names use explicit, provenance-selected union arms. No local mechanism confiscates part of a peer-selected integer namespace."
supersedes: []
superseded_by: []
amends: [ADR-0069]
amended_by: []
---

# ADR-0091 Disjoint wire and local names

> **Implementation standing.** Routed capabilities use the explicit
> `Reference.routed(CapabilityRouteId)` arm and inbound answers use
> `AnswerName.wire` / `.virtual`. Every `u64` remains valid in both wire
> namespaces, codecs refuse unlowered local identities, and the semantic reply
> path retains answer provenance until settlement.

## Problem

CapTP gives each session independent `u64` import, export, and answer
namespaces. Pancake also needs local names that do not exist on the wire:

- a Node route for a capability whose real import belongs to one particular
  session;
- a synthesized inbound answer for the V1.0 resolver-only call shape.

Reserving a high band inside a wire namespace makes the two sets disjoint only
by rejecting otherwise-valid peer input. A classifier such as `id >= base`
centralizes that rejection but does not remove it. It also lets a local route
masquerade as a wire reference until every consumer remembers to classify it.

## Decision

Local and wire names are distinct by representation, not magnitude.

```text
Reference.far(ImportPosition)       partner-selected wire import
Reference.routed(CapabilityRouteId) Node-selected local route

AnswerName.wire(AnswerPosition)     partner-selected wire answer
AnswerName.virtual(VirtualAnswer)   Session-selected local answer
```

Provenance chooses the arm. There is no constructor that guesses from an
integer, and the numeric spaces may overlap freely. A routed reference is POD
and adds no allocation or copy. It may exist in an owned or borrowed semantic
value while work is staged, but a codec refuses it; the Node must replace it
with the real session-scoped reference first.

The answer union follows the same rule. Unlike routed references, it also
crosses the application reply seam: a resolver-only delivery needs to retain its
virtual provenance until the application settles it. Events expose the raw
deliver without inventing a wire answer and expose its semantic `AnswerName`
separately; actors, Host promises, handoff, bootstrap responders, and session
consequence queues carry that name through commit.

## Consequences

- A peer may select any representable `u64` import or answer position,
  including the old reserved boundaries and `maxInt(u64)`.
- Ordinary wire references take one union-tag branch and no map lookup. Routed
  references take the existing Node route lookup. No wire-path allocation or
  copy is added.
- Node route counters remain monotonic and never reuse an id. A stale routed
  arm therefore fails closed even after its row is removed.
- Virtual answer counters are monotonic, return a typed exhaustion failure
  instead of wrapping, and may numerically equal a live wire answer without
  aliasing it. Wire `op:gc-answers` can retire only the wire arm.
- `model.Reference` and `model.view.Reference` both carry the routed arm because
  an application-owned message may be copied before Node staging. Codecs never
  decode that arm and reject it if lowering was bypassed.
- The old `REDEEMED_TOKEN_BASE`, `VIRTUAL_INBOUND_ANSWER_BASE`, numeric
  classifiers, and high-position refusals disappear. Tests prove high wire
  positions, equal-valued local identities, stale-name refusal, and typed
  exhaustion through the recurring gate.

## Rejected alternatives

- **Move the reserved boundary.** This preserves the protocol gap.
- **Classify by map membership.** An ordinary wire import equal to a live route id
  would alias it, recreating the defect under a different predicate.
- **Store a sidecar boolean beside `FarRef`.** The tag could contradict the
  payload and would burden every wire reference. The reference sum already
  owns the distinction.
- **Let bindings remember a home session.** That duplicates routing policy and
  identity in every adapter. Bindings consume opaque Host capabilities; the
  Node remains the route authority.
