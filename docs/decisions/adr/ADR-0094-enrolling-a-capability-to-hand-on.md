---
id: ADR-0094
status: superseded
date: 2026-07-29
tags: [captp, handoff, host, identity]
decision: "An application explicitly enrolls a session capability under a node-unique token before handing it to a third party; ADR-0096 supersedes this optional application contract with automatic Host-scoped lift."
supersedes: []
superseded_by: [ADR-0096]
amends: []
amended_by: []
---

# ADR-0094 Enrolling a Capability to Hand On

> **Scope of supersession.**
> Superseded by [ADR-0096](ADR-0096-host-scoped-capability-identity.md). The
> problem this record names is real and still solved: a capability an
> application received from any path, not only from `fetch`, can be handed to a
> third party. What does not stand is the answer. An application no longer
> enrolls a capability under a node-unique token before handing it on; every
> capability an application holds is already one opaque Host identity, so the
> lift is automatic and the explicit enrollment verb is gone. This record
> remains the history of the displaced design.

## Problem

A three-party handoff starts when an application replies to a call with a
capability that lives on another connection. The node notices, claims the
reply, and turns it into a signed give. That noticing is
`Node.interceptFulfilledRoute`, and it works by looking the reply's capability up
by token to find the connection it is homed on.

Only one path ever minted such a token. `Host.enrollFetched` ran on a vow whose
kind was `fetch`, so a capability obtained through `Host.fetch` could be handed
on and nothing else could. A capability returned from an ordinary call, or
lifted from a delivered argument, arrived as a plain wire position. The
intercept looked it up, found no home, and declined, so the reply went out as a
raw position that names nothing on the recipient's session.

That is not a corner. An application that receives a capability from one member
and introduces another member to it is doing the ordinary thing that a
capability system is for, and it could not.

## Decision

Add `driver_core.Host.enrollCapability`, expose it natively and as
`pancake_host_session_enroll_capability`, and give every binding a
`session.enroll` that takes a capability and returns one naming the token.

**An explicit verb, not blanket enrollment.** The alternative considered was
enrolling every settled far value, dropping the `fetch` condition in
`settleRow`. It was rejected for three reasons, the first decisive: it does not
cover the case that motivated the work, because a capability lifted from a
delivered argument never passes through a vow settlement at all. It would also
change the id every existing consumer sees, and a token answers to `gcRelease`
while a wire position answers to `releaseImport`, so replies would start coming
back with handles that no longer match the release verb an application was
using. Finally, the first enrollment sets `Node.foreign_active`, which switches
on the per-send lowering walk that a two-party peer currently skips for a single
bool load.

**The kind is the caller's to supply.** A far reference encodes as `desc:export`
whatever it points at, so the import row records a position and nothing about
its settledness (`session.slot`'s `remote_value` carries no kind field). The one
place a received reference's promise-ness survives is the reference the
application was handed, which is why `enrollCapability` takes it as a parameter
rather than reading it back off the session. Routing depends on it:
`Node.proxyForeignPromiseFulfill` claims a fulfilled *promise* token and
declines anything else, so a promise enrolled as an object reaches a third party
as a bare position it cannot wait on. In the bindings this costs the caller
nothing, since
each already holds the promise flag on the `Ref` it is asked to enroll and
forwards it as the reference's `sub_kind`.

**A position cannot wear both kinds.** Enrollment is idempotent per import, so a
second enroll of one position is answered with the first one's token. The kind,
though, lives on the row that token names, and routing reads it there. So
`Node.enrollForeign` reports the row's kind rather than the caller's request,
which is the only answer that describes where the token actually points, and
`Host.enrollCapability` turns a disagreement between the two into
`EnrolledKindConflict` rather than handing back a reference whose kind the
caller did not ask for. A fresh enroll cannot conflict, since the row is created
with the kind asked for; only naming one position under both kinds does. The
native `driver.Session.enroll` takes and returns a whole `model.FarRef`, so on
that tier a position and a kind that disagree are unconstructible, and the
refusal is there for the C-shaped tiers that take the two apart. Those tiers
also refuse a `kind` that is neither sub-kind, rather than reading an unknown
value as object: a caller that passed the wrong field would otherwise get a
silently object-kinded token back. The token fast path is the one place `kind`
is ignored, because a token is already routable and the row it was minted from
holds the kind.

**The rule is the import row.** A position with no row on the session is
refused `ForeignArgument`. Usually it names nothing there, and minting a token
would route a later gift to a capability the partner never exported. The row is
also where `Node.enrollForeign` remembers the token a capability already holds,
so a position without one could not be enrolled idempotently, and one object
wearing two identities is the hazard the idempotency exists to prevent. The
partner's pinned bootstrap is the one addressable position that can be missing
a row, and it answers to the same rule rather than an exception.

**Forgetting fails precisely.** `interceptFulfilled` now refuses a fulfilled far
the replying session does not hold. Without that the reply reached the session
spine, where the send-side reference rule refuses it as an `InvalidReference`
that tears down the whole connection over one reply. The application gets a
broken answer and a live session instead.

## Scope (what this does not decide)

- Nothing here changes what a handoff is or how one is signed. The give,
  deposit, and withdraw machinery is untouched; this only lets a capability
  reach it.
- Enrollment is not a grant. It records where a capability lives so the node can
  route a gift; deciding whether to hand it on stays the application's call.
- A gifted object must still be published, not merely spawned. A deposit carries
  a swissnum so the withdraw can re-resolve it on the recipient's own session,
  and `resolveForDeposit` refuses a near without one. That predates this
  decision and is unchanged by it.
- The returned token is released through the same `release` each binding already
  has, which routes a token and a wire position to their respective verbs.

## Alternatives Considered

- **Enroll every settled far value.** Rejected; see above. It solves the
  narrower half of the problem and charges every application for it.
- **Enroll implicitly at the reply.** The intercept could enroll a far it finds
  unenrolled instead of refusing. Rejected: at that point the node no longer
  knows which session the capability came from, only which one the reply is
  going out on, and guessing the home is how a capability gets routed to the
  wrong exporter.
- **Widen `argIsForeign` to catch raw positions.** It reports "not foreign" for
  every non-token, which is right when a message rides the connection its
  references came from. Making it session-relative would change a verdict four
  bindings share; the reply seam is where the missing home is actually known.

## Consequences

- `driver_core` gains one verb; `src/c_abi/host` gains one entry point, mirrored
  in all four bindings, each of which formerly enrolled a capability lifted
  from a reply in the now-retired enrollment handoff proof.
- `Session.holdsImport` becomes the single definition of "an import this session
  holds", asked by both the send-side reference rule and the enrollment check,
  so the two cannot drift.
- `test/driver/core_host/` holds the contract, validated by injection:
  gifting without enrolling originates no give at all, removing the reply
  refusal turns a broken answer into the session-wide `InvalidReference` it
  exists to prevent, and dropping the kind on the way to the routing row leaves
  a promise unclaimed by the proxy.
- Enrolling a promise is what lets an application introduce a third party to a
  settlement it does not own.
  [ADR-0095](ADR-0095-listening-on-a-received-promise.md) is the recipient half
  of that shape. `zig build goblins-relayed-give` runs the gifter half against a
  live Goblins pair, with a Goblins recipient doing the waiting.

## Notes

The send-side rule this leans on is
[ADR-0009](ADR-0009-three-party-handoff-substrate.md)'s handoff machinery reached through
[ADR-0069](ADR-0069-node-unique-foreign-import-identity.md)'s node-local tokens, which is
where `enrollForeign` and the route namespace live. The deliberate-release sibling
it sits beside is [ADR-0063](ADR-0063-finalizer-driven-distributed-gc.md)'s.
