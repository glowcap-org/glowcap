---
id: ADR-0172
status: accepted
date: 2026-09-15
tags: [loam, access, actors, persistence]
decision: "A managed content reply may carry a capability only through a disclosure its method declared, and the declared mode hands over a stored reference field's exact saved authority."
supersedes: []
superseded_by: []
amends: [ADR-0169]
amended_by: [ADR-0173, ADR-0182]
---

# ADR-0172 Explicit disclosure of returned capabilities

## Context

ADR-0169 gives managed use endpoints their reply path, and ADR-0170 lets a
reply carry a capability only when the service itself minted it through
derivation. What was missing is the application's half: a `ContentBehavior`
received a `ContentCall` that could not produce a capability at all, so a
managed content method could not disclose a stored reference field even when
that disclosure was the method's entire purpose. The
[managed storage plan](../../planning/loam/access/storage.md) requires the
opposite of an ambient escape: applications declare which methods disclose a
reference, and a limited view must not unwrap a stored original merely
because it can read one.

## Decision

`ContentCall.discloseExact(index)` declares that this method's reply hands
over a stored reference field's exact saved authority: the strong edge
`index` of the bound content record, restored through the retained call's
ordinary stored-edge custody (`hosting.Call.storedEdge`). The returned value
may travel in the reply, direct or nested. Every capability value in a
managed content reply must have been declared this way. The retained call's
single capability walk checks the declaration while preparing reply custody
and refuses anything else as `UndeclaredDisclosure`, whatever its origin. A
weak edge retains nothing and stays refused as `NotDurable`. An unknown field
is refused as `NoSuchEdge`.

The declaration is explicit per invocation, not per schema: the trusted
application names the disclosure where it happens, and the machinery fails
closed when the reply carries a capability the method never named, including
an attachment-local capability obtained from outside the call.
Declared disclosure restores at invocation, while the Store is idle; a
revision restart re-runs the method and converges on the same target entry.
Derivation replies are unaffected: the service builds and bounds those
itself (ADR-0170). Owning replies still obey the local-resolver rule
(`OwningReplyRequired`); capability disclosure settles through a Host
resolver.

## Scope (what this does not decide)

This decision covers exact disclosure only. ADR-0173 adds a dependent mode
whose per-call admission checks both the invoking endpoint and the stored
target. Stored foreign references, capability-valued content fields, and the C
ABI and Rust projection of the disclosure API remain in the
[managed storage plan](../../planning/loam/access/storage.md).

## Alternatives Considered

- **Let `ContentBehavior.invoke` return capabilities and trust the
  application.** Rejected: the disclosure policy would stay ambient in
  application code, invisible to the authority model, which is exactly the
  shape the plan forbids.
- **Model disclosure as a per-schema declaration on `ContentBehavior`.**
  Rejected: the plan asks for per-method declarations, and a schema-level
  flag cannot distinguish a container view handing out an original from one
  that declines to.
- **Route disclosure through derivation (ADR-0170).** Rejected: derivation
  mints new grant authority for the same fixed resource binding. Passing a
  stored reference's existing authority is a different fact and needs no
  new grant or write.

## Consequences

`hosting.Call` generalizes `edge` into `storedEdge(view, index)` so a call can
restore a stored reference field of any record view it holds. `edge` delegates.
The application receives an opaque `ContentCall`, so it cannot rewrite the
bound view or disclosure ledger. Declarations use a window in the call's
existing held-capability list. The marker costs one `usize` in each pending
call and adds no disclosure container or allocation. `Value.forEachCapability`
owns one allocation-free, depth-bounded walk for both plain-value checks and
reply custody. Tests own both halves: an in-process suite proves every composite
value arm fails closed, and a CapTP wire suite proves a nested disclosed
reference crosses a real session as a callable capability while an undeclared
one breaks with `UndeclaredDisclosure`.

## Evidence and verification

`test/loam/access/hosting_test.zig` covers declared and undeclared capabilities
in direct, list, set, tagged, and struct replies. It also covers weak-edge and
unknown-field refusal plus the local-resolver rule.
`test/loam/access/hosting_wire_test.zig` covers nested wire delivery,
callability, and refusal over a live session. The native LMDB
managed-hosting suite reopens a store and proves the stored reference field
discloses after restart. All run under `zig build check`; the existing
derivation and managed-turn suites are unchanged by this check.
