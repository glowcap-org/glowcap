---
id: ADR-0052
status: accepted
date: 2026-06-11
tags: [engine, session, pipelining, untag, tagged]
decision: `op:untag` is an OCapN 1.0 operation and both profiles answer it through the ADR-0050 projection substrate. Glowcap sends it only when the partner explicitly advertised the `untag` feature; an absent feature hint excludes it because Goblins has no such operation. A matching tag unwraps the Tagged payload (the single value when the payload has one, the value List otherwise) and a mismatched tag or a non-Tagged fulfillment breaks the projected answer. The tag is a Syrup String on the wire, matching op:get's field-name choice.
supersedes: []
superseded_by: []
---

# ADR-0052 The op:untag responder

## Context

ADR-0050 built the projection substrate: session-owned `Projection` rows
anchored on the receiver answer, drained by the resolve seam: and shipped
`op:get` / `op:index` on it, naming `op:untag` as the one projection still
outside. The spec settles untag's wire shape and receive contract (CapTP §
op:untag): `<op:untag receiver-desc tag new-answer-pos>` exports a promise at
`new-answer-pos` that resolves to the Tagged payload when the asserted tag
matches the receiver's eventual Tagged, and rejects when it does not. One model
mismatch needed a decision: the spec's Tagged carries a single value, while
glowcap's `model.Tagged` carries the Goblins `user-record` payload as a slice
(ADR-0021), and real payloads in the tree are zero-, one-, and two-valued.

## Decision

- **Untag is a third `ProjectionKind` arm.** `.untag` owns its tag bytes exactly
  as `.field` owns its name; install, anchoring, re-anchoring, hop bounds, the
  projection cap, and the drain seam are the ADR-0050 machinery unchanged.
- **Unwrap is total and guess-free.** A matching tag with a single-value payload
  fulfills that value (the spec's case). Any other arity fulfills the payload as
  the List it already is, so a variadic Goblins-shaped payload is neither
  truncated nor invented into a single value. A mismatched tag and a non-Tagged
  fulfillment break with typed reasons; a broken receiver passes its break
  through.
- **The tag is a Syrup String on the wire**, matching the op:get field-name
  choice the spec and live Goblins settled for ADR-0050.
- **The initiator half is symmetric and explicitly negotiated.** Sending
  `op:untag` validates the receiver like a deliver target and installs the
  projected answer outbound on either wire version, but only when the session
  negotiated `FeatureSet.untag`. Refusal occurs before answer state mutates.
- **Inbound support is not feature-gated.** The pinned 1.0 draft defines the
  operation. A conforming peer may send it even when it knows nothing about
  Glowcap's hint vocabulary, so both owned and borrowed receive paths validate
  and answer it on 1.0.

## Scope (what this does not decide)

- Goblins has no `op:untag` marshaller. Its absent feature hint therefore keeps
  Glowcap from sending the operation accidentally, while accepting one remains
  the standards-correct behavior. The authority is the pinned spec text, the
  wire-driven engine scenarios, and the upstream-Racket-generated fixture.
- The tag-namespace question upstream is discussing for user tags (meeting
  minutes 2025-10-14) is the application's: glowcap matches the tag bytes the
  wire carries.

## Consequences

- Both profiles answer all three projection ops. Outbound `op:untag` is
  available when both peers advertise it, independently of the version axis.
- The untag scenarios (single-value unwrap, variadic List unwrap, tag mismatch,
  non-Tagged receiver, outbound install) ride the same wire-driven suite as
  get/index, and the codec corpus pins the wire shape in Syrup and Cap'n Proto
  against the upstream Syrup encoder.
