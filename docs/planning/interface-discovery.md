# Interface discovery

Status: conditional plan, waiting for a concrete consumer and maintainer review.
A separate proposal above the [interface architecture](../decisions/adr/ADR-0069-proposed-interface-language.md).
Generation does not depend on discovery. Delete this plan when discovery lands
or is removed from scope.

## What this is for

Let a caller explicitly request an unfamiliar object's alleged interface when
a committed description cannot reasonably meet the need. This feature requires
a consumer that justifies its authority, privacy, and maintenance costs.

## Where things stand

Loam describes grant state, not general method interfaces. MCP tools are
hand-wired. The [prior-art review](../research/interface-goblins.md) covers
Spritely's interface research and separately held inspection authority.
It does not establish community endorsement of a glowcap convention.

## The decision

Choose the mechanism only after establishing that consumer. Compare an opt-in
namespaced method with a separately held description capability. A universal
reserved method does not fit actors without method dispatch, and forwarding
an inspection request can reveal an underlying object's broader interface.
Keep discovery outside engine dispatch and mandatory handshakes.

Descriptions are untrusted data. Shape agreement proves neither implementation,
permission, read-only effects, nor retry safety. Refusal, timeout, stale data,
or a malformed answer must not prevent ordinary calls. Facets and forwarders
answer for their own exposed view or refuse rather than silently inspecting a
more powerful underlying object.

Use a content digest for complete descriptions and unchanged replies.
Cache entries must neither extend capability lifetimes nor merge authority
between unrelated references. Described behavior can change independently of
content. Structural comparison and shape hashes require a separate justified
consumer and proof, including bounded recursive comparison and an unknown result.

Bound input size, type nodes, nesting, allocations, canonicalization work,
time, and cache use. Names, labels, enums, and notes are all untrusted when
shown to people or supplied to an agent. Omitting prose notes does not make
other strings safe instructions.

## Steps

1. **Qualify the need and authority.** Record the consumer, alternatives,
   inspection authority, forwarding rules, and costs in an ADR for review.
   Specify a success case that committed descriptions cannot reasonably serve.
   No query implementation starts without this decision.
2. **Implement one bounded path.** Query one generated Tasks service explicitly.
   Test full and unchanged replies, content-only changes, unsupported queries,
   misleading descriptions, malformed data, timeouts, cancellation, and budgets.
   Ordinary calls must remain available without any query.
3. **Prove restricted views.** Exercise read-only, paused, revoked, restricted,
   and forwarded references. Inspect only the authority explicitly granted.
   Test accidental forwarding to a broader interface and cache lifetime cleanup.
4. **Add the consumer.** Treat every textual field as untrusted content and
   keep call authorization independent of description retrieval.
   If human approval of notes is offered, bind it to the source reference and
   complete content digest. Test instruction-shaped names as well as notes.
5. **Qualify and document the convention.** Use plain Goblins peers in both
   directions without discovery, including ordinary access to methodless actors.
   Record exact role and transport coverage and supported consumers.
   Upstream communication remains a separate human-authored maintainer action
   under [PROVENANCE.md](../../PROVENANCE.md#upstream-policies).

## Parallel work

The decision and first query have one owner. Restricted-view tests and consumer
integration may then separate by file ownership. Integration owns the ADR,
shared helpers, plan, and evidence. Interop follows both lanes.

## Questions for you

- Which consumer justifies live discovery?
- Should inspection require a separate capability or be available to holders
  of the participating object?

## Where the code is

| Concern | Where |
| --- | --- |
| Generated adapters | `tools/interface/` |
| Facets and forwarding | `src/loam/access/hosting/`, `src/actors/` |
| CLI and MCP consumers | `cli/` |
| External evidence | `conformance/goblins-peer/`, [community review](../community-review.md) |

Use `source-check` for the decision, focused `test` and `runtime-check` for
queries and lifetimes, consumer tests for presentation, and `check-external`
for interop. Final gates follow the implemented runtime and consumer scope.
