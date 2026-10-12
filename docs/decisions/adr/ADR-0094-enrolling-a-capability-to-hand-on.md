---
id: ADR-0094
status: superseded
date: 2026-07-29
tags: [captp, handoff, host, identity]
decision: "An application explicitly enrolls a session capability under a node-unique token before handing it to a third party. ADR-0096 supersedes this optional application contract with automatic Host-scoped lift."
supersedes: []
superseded_by: [ADR-0096]
amends: []
amended_by: []
---

# ADR-0094 Enrolling a Capability to Hand On

> **Scope of supersession.**
> Superseded by [ADR-0096](ADR-0096-host-scoped-capability-identity.md). The
> problem this record names stands: a capability an application received from
> any path, not only from `fetch`, can be handed to a third party. The answer
> does not. Every capability an application holds is one opaque Host identity,
> so the lift is automatic and no enrollment verb exists. This record is the
> history of the displaced design.

## Problem

A three-party handoff starts when an application replies to a call with a
capability that lives on another connection. The node notices, claims the
reply, and turns it into a signed give. That noticing is
`Node.interceptFulfilledRoute`, and it works by looking the reply's capability up
by token to find the connection it is homed on.

Only one path mints such a token. `Host.enrollFetched` runs on a vow whose
kind is `fetch`, so only a capability obtained through `Host.fetch` can be
handed on. A capability returned from an ordinary call, or lifted from a
delivered argument, arrives as a plain wire position. The intercept looks it
up, finds no home, and declines, so the reply goes out as a raw position that
names nothing on the recipient's session.

An application that receives a capability from one member and introduces
another member to it is doing the ordinary thing a capability system is for.

## Decision

Add `driver_core.Host.enrollCapability`, expose it natively and as
`glowcap_host_session_enroll_capability`, and give every binding a
`session.enroll` that takes a capability and returns one naming the token.

**An explicit verb.** Enrolling every settled far value (dropping the `fetch`
condition in `settleRow`) was rejected for three reasons. It does not cover the
motivating case, because a capability lifted from a delivered argument never
passes through a vow settlement. It changes the id every existing consumer
sees, and a token answers to `gcRelease` while a wire position answers to
`releaseImport`, so replies would come back with handles that no longer match
the release verb an application uses. And the first enrollment sets
`Node.foreign_active`, which switches on the per-send lowering walk that a
two-party peer skips for a single bool load.

**The caller supplies the kind.** A far reference encodes as `desc:export`
whatever it points at, so the import row records a position and nothing about
its settledness (`session.slot`'s `remote_value` carries no kind field). A
received reference's promise-ness survives only in the reference the
application was handed, so `enrollCapability` takes the kind as a parameter.
Routing depends on it: `Node.proxyForeignPromiseFulfill` claims a fulfilled
promise token and declines anything else, so a promise enrolled as an object
reaches a third party as a bare position it cannot wait on. In the bindings
each caller already holds the promise flag on the `Ref` it enrolls and forwards
it as the reference's `sub_kind`.

**A position has one kind.** Enrollment is idempotent per import, so a second
enroll of one position is answered with the first one's token. The kind lives
on the row that token names, and routing reads it there. So
`Node.enrollForeign` reports the row's kind, which describes where the token
points, and `Host.enrollCapability` turns a disagreement with the request into
`EnrolledKindConflict`. A fresh enroll cannot conflict, since the row is
created with the kind asked for. Only naming one position under both kinds
does. The native `driver.Session.enroll` takes and returns a whole
`model.FarRef`, so on that tier a disagreeing position and kind cannot be
constructed, and the refusal serves the C-shaped tiers that take the two apart.
Those tiers also refuse a `kind` that is neither sub-kind, so a caller that
passes the wrong field never gets a silently object-kinded token. The token
fast path ignores `kind`, because a token is already routable and the row it
was minted from holds the kind.

**The rule is the import row.** A position with no row on the session is refused
`ForeignArgument`. Usually it names nothing there, and minting a token would
route a later gift to a capability the partner never exported. The row is also
where `Node.enrollForeign` remembers the token a capability holds, so a position
without one could not be enrolled idempotently, and one object with two
identities is the hazard idempotency prevents. The partner's pinned bootstrap is
the one addressable position that can lack a row, and it follows the same rule.

**Forgetting fails narrowly.** `interceptFulfilled` refuses a fulfilled far the
replying session does not hold. Otherwise the reply reaches the session spine,
where the send-side reference rule refuses it as an `InvalidReference` that
tears down the connection over one reply. The application gets a broken answer
and a live session.

## Scope (what this does not decide)

- The give, deposit, and withdraw machinery and handoff signing are unchanged.
  Enrollment lets a capability reach them.
- Enrollment is not a grant. It records where a capability lives so the node can
  route a gift. The application decides whether to hand it on.
- A gifted object must be published, not only spawned. A deposit carries a
  swissnum so the withdraw can re-resolve it on the recipient's session, and
  `resolveForDeposit` refuses a near without one.
- The returned token is released through the same `release` each binding already
  has, which routes a token and a wire position to their respective verbs.

## Alternatives Considered

- **Enroll every settled far value.** Rejected, as above. It solves half of the
  problem and charges every application for it.
- **Enroll implicitly at the reply.** The intercept could enroll a far it finds
  unenrolled instead of refusing. Rejected: at that point the node no longer
  knows which session the capability came from, only which one the reply is
  going out on, and guessing the home is how a capability gets routed to the
  wrong exporter.
- **Widen `argIsForeign` to catch raw positions.** Rejected. It reports "not
  foreign" for every non-token, which is right when a message rides the
  connection its references came from. Making it session-relative would change
  a verdict four bindings share. The reply seam is where the missing home is
  known.

## Consequences

- `driver_core` has one verb. `src/c_abi/host` has one entry point, mirrored in
  all four bindings.
- `Session.holdsImport` becomes the single definition of "an import this session
  holds", asked by both the send-side reference rule and the enrollment check,
  so the two cannot drift.
- `test/driver/core_host/` holds the contract, validated by injection:
  gifting without enrolling originates no give at all, removing the reply
  refusal turns a broken answer into the session-wide `InvalidReference` it
  exists to prevent, and dropping the kind on the way to the routing row leaves
  a promise unclaimed by the proxy.
- Enrolling a promise lets an application introduce a third party to a
  settlement it does not own.
  [ADR-0095](ADR-0095-listening-on-a-received-promise.md) is the recipient half
  of that shape. `zig build goblins-relayed-give` runs the gifter half against a
  live Goblins pair, with a Goblins recipient doing the waiting.
  `zig build goblins-listen-recipient` runs the reciprocal live half, with the
  owning native Session waiting on Goblins' promise and calling a capability
  nested in its later settlement.

## Notes

The send-side rule this leans on is
[ADR-0009](ADR-0009-three-party-handoff-substrate.md)'s handoff machinery
reached through [ADR-0069](ADR-0069-node-unique-foreign-import-identity.md)'s
node-local tokens, which is where `enrollForeign` and the route namespace live.
Its release sibling is
[ADR-0063](ADR-0063-finalizer-driven-distributed-gc.md)'s.
