---
id: ADR-0101
status: accepted
date: 2026-08-01
tags: [actors, host, identity, lifetime, publication]
decision: "A Host-composed Vat actor lives exactly as long as its explicit roots: the host-wide alias row, the Host capability slot, each Port export binding, and each exact gift row hold one root apiece, transferred and released at the seam that owns the relationship. The count reaching zero retires the actor's row and box at the next outermost-turn boundary. Queued turns do not root; a drained turn to a reclaimed target takes the established typed NoSuchActor refusal."
supersedes: []
superseded_by: []
amends: [ADR-0060, ADR-0096]
amended_by: []
---

# ADR-0101 Actor roots and reclamation

## Status

Accepted and implemented. The Vat-tier root mechanics — retain and release,
the deferred retire past a running frame, the tolerated no-op on an absent
row, the queued-turn refusal, and restore's intersect rule — are held by
`test/actors/actor_roots_test.zig`. The composition's rooting relationships
are held by the production Host scenarios: the alias, gift, export-binding,
and session-closure roots in `test/driver/core_host/actors_test.zig` (the unpublish
scenario's reclamation tail), and the owning-tier release-reclaims case with
the `Hosting` deinit forwarding in `test/driver/actor_reclaim_test.zig`.
ADR-0096 deliberately left actor reclamation at Host lifetime; this record
ends that boundary.

## Context

Before this decision, a Host-composed Vat retained every actor box until Host
teardown. Session closure and the final release of an opaque capability
removed projections and registry rows but never the actor, so a long-lived
Host leaked one box per retired object. ADR-0096 named the missing
prerequisite: an explicit roots policy spanning aliases, gifts, projections,
queued turns, and application retains, so that collection never infers
liveness from a single surface and session closure never impersonates actor
ownership.

Two properties of the existing design shape the answer:

- The base Vat API hands out plain `actors.Ref` values with no retain
  discipline, and the borrowing tier co-owns its Vat. Reclamation is therefore
  a policy of the standard Host composition's rooting relationships, not a
  tracing collector over application memory.
- The engine and Vat already fail a delivery to a missing actor closed with a
  typed `NoSuchActor` refusal (an answered delivery breaks its answer; a
  one-way delivery is refused locally; the session stays open). ADR-0096's
  restore semantics established that path; reclamation reuses it instead of
  inventing a second missing-target behavior.

## Decision

### The root set

Each Vat actor row carries an explicit root count. Exactly these
relationships hold roots in the standard composition:

- **The spawn root.** `Vat.spawn` mints the row with one root owned by the
  spawn's caller. On the borrowing tier and the pure-local Vat that root is
  never released, which is precisely the old contract: those callers co-own
  the Vat, and their actors live to teardown unless they release explicitly.
- **The host-wide alias row.** `Host.publishGiftable` transfers the fresh
  actor's spawn root to the alias row. Replacement releases the displaced
  actor's alias root; `unpublish` releases the named actor's alias root.
- **The Host capability slot.** Creating the canonical local slot on first
  lift retains one root; retiring the slot on final application release
  releases it. Application retains and releases inside a live slot move the
  slot's own count, never the actor's.
- **A Port export binding.** `Port.bindExport` retains one root per bound
  actor; unbinding, rollback, and Port teardown release it. A partner holding
  a near export is real authority, so the projection legitimately roots the
  actor — what this record forbids is treating projection as the *only*
  signal.
- **An exact gift row.** Deposit capture retains one root through the local
  projection seam; the row's death releases it through the same seam, whether
  the row is consumed by withdrawal (after the destination Port's projection
  has taken its own root), replaced by a re-deposit, or destroyed with its
  session's Peer. Session closure thereby releases exactly the retains that
  session held — its projections and its gift rows — and nothing else.

The owning tier's spawn and publish verbs (`driver.Session.spawn` /
`publish`, `HostTurn.spawn`, the C session spawn) release the spawn root once
the durable relationship they create — the capability slot, plus any export
binding — holds its own, so an application that drops its last handle drops
the actor.

### What does not root

Queued local turns, vows, listeners, and in-flight replies hold no root. A
drained turn whose target row was reclaimed takes the typed `NoSuchActor`
refusal the restore seam already defines. Mid-turn state safety is the box
refcount's job, not the row's: releasing the last root retires the row at
once but parks the box on the Vat's retired list, freed at the next
outermost-turn boundary, so a handler that releases its own last root runs
its turn to completion on live state.

### Restore intersects, never resurrects

Roots are authority and are never rewound (the same rule ADR-0096 gives
capability rows and publications). `restore` swaps state boxes only for
actors present in both the snapshot and the current table, keeping each
current row's root count; a row created after the snapshot is removed as
before, and a snapshot-only row — one reclaimed since the snapshot — is not
resurrected, because no surviving authority could reach it and a rootless
resurrected row would be exactly the leak this record removes. Rooting
relationships that outlive a restore-removed row fail closed: retains and
releases on an absent row are tolerated no-ops.

## Cost and lifetime posture

One `u32` per actor row, and one counter bump per rooting relationship's
create and destroy. The warmed local queue batch stays allocation-free and
pays no per-turn count traffic, because queued turns do not root. Reclamation
itself reuses the retired-box list ADR-0060 already drains at the
outermost-turn boundary.

## Required evidence

Items 2, 3, 6, 7, and 8 are held by
[`test/actors/actor_roots_test.zig`](../../../test/actors/actor_roots_test.zig)
and the unpublish scenario's reclamation tail in
[`test/driver/core_host/actors_test.zig`](../../../test/driver/core_host/actors_test.zig);
items 1, 4, and 5 by
[`test/driver/actor_reclaim_test.zig`](../../../test/driver/actor_reclaim_test.zig)
together with that same Host scenario and ADR-0100's gifter-close scenario.

1. An owning-tier `spawn` whose capability is released is reclaimed while its
   session stays open, before Host teardown.
2. An alias published and never fetched is reclaimed by `unpublish` alone.
3. An alias fetched on one Port survives `unpublish` through its export
   binding, and closing that session reclaims it.
4. A deposited exact gift roots its actor after `unpublish` and after the
   projecting session closed; consuming the withdrawal transfers the root to
   the destination Port, and closing that Port with no remaining handles
   reclaims the actor.
5. Closing the Gifter–Exporter session destroys its gift rows and releases
   their roots (ADR-0100's teardown), without touching roots other sessions
   or the application hold.
6. A queued turn drained after its target's last root released takes the
   typed `NoSuchActor` refusal and the session stays open.
7. A handler that releases its own last root completes its turn on live
   state; the box frees at the boundary (held by the testing allocator).
8. A reclaimed actor is not resurrected by `restore`.

## Alternatives Considered

- **Tracing collection over the composition.** Rejected: the base tier's bare
  `actors.Ref` values are invisible to a tracer, so a trace would either free
  live actors or require retain discipline anyway.
- **Rooting queued turns.** Rejected: it buys nothing the typed refusal does
  not already define, and charges every local send a retain/release pair.
- **Session closure deleting the actors it projected.** Rejected by
  ADR-0096's identity rule: a session owns its projections, never the actor.
- **Reclaiming on Port-projection absence alone.** Rejected: projection is
  one root among several; gifts and application handles keep unprojected
  actors alive.

## Consequences

- `docs/boundaries.md` drops "local actors are retained for the Host
  lifetime"; the alias verbs stay discovery-only while the roots they hold
  become explicit.
- ADR-0060's retired-box boundary gains a second producer: root-zero
  reclamation parks boxes beside `become`'s displaced boxes.
- ADR-0096's "actor reclamation is currently Host-lifetime" context is
  superseded by this policy; its restore evidence (item 10) keeps its exact
  semantics, now shared with reclamation's missing-target path.
