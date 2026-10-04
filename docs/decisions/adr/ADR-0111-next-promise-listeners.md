---
id: ADR-0111
status: accepted
date: 2026-08-06
tags: [captp, next, promises, op-listen, shortening, settlement]
decision: "The next profile follows OCapN PR 282: answered operations have no inline resolver and are followed by a mode-3 listen; every received remote promise gets one private mode-1 shortening listen; callbacks settle application answers or advance session-owned forwarding; next sends no wire op:resolve."
supersedes: []
superseded_by: []
amends: [ADR-0007, ADR-0095]
amended_by: []
---

# ADR-0111 Next promise listeners

## Context

The pending OCapN promise-listening proposal removes `resolve-me-desc` from the
next `op:deliver`, assigns integer modes to `op:listen`, and requires a
shortening-capable listener after every operation that creates an answer. It
also requires one after receiving a remote promise. Goblins V1.0 keeps its
inline resolver and Boolean `wants-partial?` form.

## Decision

The next profile follows that proposal. An answered `op:deliver`, `op:get`,
`op:index`, or `op:untag` is queued together with a mode-3 listen. The operation
always precedes its listener on the wire. Its callback settles the application's
answer through the existing resolver-export path. Next never encodes or accepts
wire `op:resolve`.

A promise received in an argument or shortening callback gets one private
mode-1 listen. Its resolver export is session maintenance, not an application
answer. A callback must fulfill with a far promise. The session records that
forwarding edge, subscribes to the returned promise, rewrites later outbound
references through the chain, and refuses duplicate callbacks or cycles. Each
edge remains stable because it owns the callback-introduced import retain; GC
releases that target, transitively, with the source.

One promise incarnation may also carry one mode-2 wire settling listener. When
its mode-1 callback shortens to a target without one, that listener is reissued
against the target with the same resolver. When two listened promises shorten
to the same target, the target's existing wire listener survives and the local
application answers and Node proxy recipients fan out behind its callback. No
second settling listener crosses the wire.

Local answer release unlinks one fan-out consumer in O(1). Releasing the
primary promotes a follower; releasing the final application consumer leaves
the Node consumer in control when one exists. Otherwise the resolver becomes a
pending tombstone: one callback already in flight is admitted and its imports
are immediately released, while a duplicate is refused. The resolver export's
local baseline remains until the partner releases its wire mention, preserving
the export table's `baseline + wire-held` accounting.

Releasing the source import does not cancel a live settling consumer. If the
promise later shortens, the consumer is rearmed on the target before that
callback-introduced import is returned. A retired consumer is not rearmed;
shortening concludes its pending tombstone because the old settling-only
listener was discarded.

The neutral model uses `ListenMode`. Syrup and Cap'n Proto translate Goblins's
V1.0 Boolean or next's integer at the codec edge. Same-peer promise fulfillment
re-anchors a listener without notification. On next, a far promise satisfies a
shortening mode, and a settled value or break satisfies a settling mode. V1.0
has no paired shortening listener, so a far promise concludes every V1.0
listener (ADR-0007). Every
notification concludes its subscription.

## Consequences

- V1.0 wire behavior remains Goblins-compatible.
- Next tracks the pending proposal rather than the pinned settled draft.
- Mandatory operation/listen pairs are prepared before session authority is
  committed, so allocation failure cannot leave an answered operation without
  its listener.
- Promise forwarding remains session authority. Codecs only parse and render
  the profile-specific forms.
- Shortening leaves one settling-listener claim on the target and merges local
  consumers before callback dispatch, including mixed application and Node
  ownership.
- Answer GC, Node proxy teardown, and callback delivery each conclude only the
  consumer or retain they own; none turns a racing callback into an application
  call or over-releases the resolver export.

## Evidence

Codec tests pin each profile's deliver and listen arity. Session and engine
tests cover mandatory listener ordering, settlement callbacks, recursive
shortening, settling-listener rearming and convergence, mixed application and
Node fan-out, reference rewriting, duplicate refusal, cycle refusal,
transitive GC, rollback, and the steady peer footprint budget.
