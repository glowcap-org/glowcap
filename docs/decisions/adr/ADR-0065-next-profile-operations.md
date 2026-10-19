---
id: ADR-0065
status: accepted
date: 2026-10-19
tags: ["captp", "next", "conformance", "negotiation", "promises"]
decision: "The next profile adopts the merged delivery and listen contracts and removes projections."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0065 Next-profile operations

## Context

The upstream draft can change operation semantics independently of session cryptography. Adopting a merged operation does not establish support for every newer draft field.

## Decision

The next profile adopts the merged delivery and listen contracts and removes projections. It retains the shared four-field hello and existing cryptographic representations until the coordinated transition is supported.

One fingerprinted manifest records adopted, deferred and pending sections and governs suite adaptation. Updating the specification reference does not silently change the implementation claim. Shared suite changes require fixture review.

The next suite includes the baseline lane, fixture regressions, adapted upstream assertions and draft-native cases. The adapter implements those declared cases rather than promising compatibility with arbitrary future upstream changes.

## Alternatives and consequences

Moving the shared hello in one private profile would change bytes sent before a peer knows the partner's profile. Claiming the complete draft would hide the crypto deferral. Freezing all operation progress behind that deferral would couple otherwise independent work.

The baseline preserves pinned Goblins interoperability. Next remains a named private profile whose exact wire identity participates in negotiation. Application protocols have their own compatibility boundaries.

## Evidence

`zig build ocapn-conformance-next` and the mixed-profile gift checks cover their named cases. [The conformance manifest](../../ocapn-conformance.md) and [upstream watch](../../upstream-watch.md) own section status and the crypto transition prerequisites.
