---
id: ADR-0191
status: accepted
date: 2026-10-04
tags: [actors, vat, turns, goblins, semantics]
decision: "An outermost Vat turn's local eventual sends take effect only when the turn returns successfully: they are admitted during the turn, queued when it returns, and dropped with their vows broken when it fails. Far sends still leave when made until the engine can retract them."
supersedes: []
superseded_by: []
amends: [ADR-0060]
amended_by: [ADR-0194]
---

# ADR-0191 Turn sends commit with the turn

## Context

A handler that sends and then fails emitted those sends anyway. The error path
discarded only the staged `become`. Goblins treats a turn as a unit: on an
exception it clears the turn's pending messages and still sends the break to the
caller (`core.rkt`, the `new-msgs` reset). A turn that throws halfway through
emitting half its effects breaks the reasoning "a turn either happens or it
doesn't", and Goblins code ported to glowcap changes behavior.

## Decision

The unit is the outermost turn: the frame opened at `turn_depth == 0`, together
with every near call it makes.

- **Local sends** made inside that turn run admission immediately, so the
  handler still sees a queue refusal, and mint their vow so `on` works. The
  cloned message goes to a staged chunk no drive can see. The Vat keeps one
  staging entry per ingress the turn sent on, so sessions pay nothing for it.
- **A successful return** splices the staged chunks onto their queues inside
  the frame, before the reply leaves it. Splicing cannot fail.
- **A failed outermost turn** drops the staged chunks, their admission charges
  and vow rows after the frame closes, and breaks listeners on the dropped
  vows with the turn's error. The break to the caller is still sent.
- **An error an outer frame catches** keeps the inner frame's sends, as in
  Goblins, because only the outermost result decides.
- **Cancelling an ingress** that holds staged sends is refused as busy until
  the turn returns.

## Far sends

Far sends still go to the Peer when made. Holding them in the Vat until commit
was tried and rejected for two reasons. A held message outlives the references
the handler releases after sending, so the send fails at commit. And the Host
lowers routed capabilities inside a transaction that lends leases only for the
duration of `Peer.send`. The workable shape is to record far sends as today and
retract them when the turn fails: a plain deliver's session effects have exact
inverses and nothing is encoded during a turn. A send the Node adopted to
project a capability needs a Node-level rollback first.
[ADR-0194](ADR-0194-far-sends-retract-with-a-failed-turn.md) decides it.

## Scope

A mutable actor's direct state changes are not rolled back. ADR-0060's limit
stands. Actors spawned during a failed turn stay alive, because the mutated
state may already hold them.

## Evidence

`test/actors/vat/turn_commit_test.zig` covers local sends dropped by a failed
near or queued turn, their vow listeners broken, admission released, sends kept
when a successful turn returns, and sends kept when an outer frame catches an
inner error.
