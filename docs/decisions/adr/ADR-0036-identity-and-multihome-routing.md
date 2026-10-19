---
id: ADR-0036
status: accepted
date: 2026-10-19
tags: ["handoff", "locator", "transport", "browser", "locators", "netlayer", "negotiation", "glowcap-next"]
decision: "The private identity-route form names a durable public key in an id locator."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0036 Identity and multihome routing

## Context

A list of addresses does not establish that those addresses reach the same capability peer. Reachability policy must retain a specific identity requirement.

## Decision

The private identity-route form names a durable public key in an id locator. Ordered via routes must prove that same key. The Node admits a bounded race of two strong routes and replenishes that window in source order.

The first completed route with the required proof wins. Only after strong routes fail can handoff-scoped alt-locators be tried serially in their declared order. Weak advice cannot outrank strong identity proof.

The negotiated private feature admits this vocabulary. Baseline handoff lowers to a compatible route without changing its canonical record arity. Generic physical dial planning does not interpret an identity bundle as a transport.

## Alternatives and consequences

An address list without a common authenticated identity cannot safely support a transport-independent sturdyref. Adding an identity field would recreate the chosen form less directly. An inert comparison vocabulary would add a branch without a usable contract.

The library assigns no hidden transport preference. Publishers order their routes, and receiver policy does not rewrite the signed ranking. Listener discovery remains application policy. These names are a glowcap-private extension, not an upstream OCapN claim.

## Evidence

Route bounds, proof requirements, cancellation, cache selection and baseline lowering run under `zig build test`. The [conformance manifest](../../ocapn-conformance.md) states the private-profile boundary.
