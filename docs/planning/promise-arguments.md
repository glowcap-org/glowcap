# Promise arguments

Status: active plan. Delete this plan when its steps land and the
[known limitations](../boundaries.md) no longer list the refusal.

## What this is for

In E and Goblins a program writes the second call before the first has
answered: ask a factory for a car, then tell the car to drive, then hand the
car to a garage, all in one breath. The third step passes a promise as an
argument. On the wire the sender names the still-open question, and the
receiver is expected to treat that name as a promise for whatever it will
answer. A promise a peer passes to glowcap this way arrives as a capability
the application can send to, wait on, or pass along. A glowcap application
cannot write the idiom itself: its handle to a pending answer is a vow, and
nothing turns a vow into a value a call can carry.

This plan makes the sending direction work and proves both against Goblins.
When it lands the conformance manifest has no protocol behavior that glowcap
refuses, apart from the cryptographic handshake it tracks against upstream in
its own plan.

## Where things stand

Promises are otherwise complete. A peer's own promise passed as an argument,
written on the wire as an imported promise, already works and is proved
against live Goblins in both directions. Sending to a promise before it
settles, which is pipelining, works and is a decision record. Listening on a
received promise works in Zig and every binding. A signed handoff that
appears inside a value already becomes a Host capability promise with its own
identity, pending operations, and settlement, so the Host has the row type
this plan needs.

An answer reference inside a call's arguments lifts to a Host capability
promise keyed by the answer, which settles when the answer does: to the
capability it names, to its data, to another lifted answer, or broken. The
per-session bound, its typed refusal, release when the application lets the
capability go, survival of the partner's garbage collection, and breaking on
session close are in place with their tests.

In the other direction an application's handle to a pending answer is a vow,
and a vow is not a value. Nothing turns it into something a call can carry.

Every other row the conformance manifest does not mark adopted is owned by
the handshake plan or is an explicit coverage limit in the upstream suite
wrapper.

## The decision

An answer reference inside arguments lifts to a Host capability promise, the
same row type a signed give uses, keyed by the answer row's identity so the
same question passed twice is one capability. The promise subscribes to the
inbound answer's settlement. The answer's notification owner already keeps a
settlement stable across the peer's garbage collection of the position, so
the lifted promise holds a retain on that payload and survives the peer
releasing the position.

The capability promise gains a third settled state beside "resolved to a
route" and "broken": "resolved to data". A send to a promise that settled to
data breaks with the same reason a peer gives when a message reaches a
non-object, and a listen on it fulfills with the data. An answer already
settled to a reference lifts as that reference, which is the shortening every
CapTP implementation performs. One already settled to data or broken lifts as
a settled promise.

Lifted promises per session are bounded by a session limit. Exceeding it
fails the one call with a typed refusal and keeps the session. Session close
breaks every lifted promise through the owner that breaks inline-give
promises. Each row is a named cost in the memory ledger.

In the outbound direction a public Host vow can be projected as a capability.
Lowered into a call on the session that owns the question, it encodes as an
answer reference. Lowered into a call on another session, it uses the local
promise projection the Node already uses to relay a third party's promise,
and settles through the same answer path. The C ABI gains one verb for the
projection, and each binding's send accepts its own promise type as an
argument by calling it.

## Steps

Each step is one commit with its own test.

5. **Project a vow outbound.** A Host verb turns a public vow into a
   capability. Same-session lowering encodes the answer reference, and
   cross-session lowering projects a local promise. The inbound lift refuses
   a reference to one of this Host's own promise exports, so a projected vow
   that comes back inside a partner's answer needs that lift to accept it.
   Test: two Hosts, a factory call followed by a pass of its unsettled result
   to another object on the same peer and on a third peer, each settling once.
6. **C ABI and bindings.** One C verb for the projection, and every binding's
   send accepts its promise type as an argument. Received promises already
   arrive as capability handles. Test per binding: pass a pending promise,
   receive one, send to it, await it.
7. **Outside evidence.** Goblins passes an answer reference to a glowcap
   object and glowcap passes one to Goblins, in the live interop step.
   Conformance rows cite the evidence. Test: `goblins-interop` and
   `ocapn-conformance`.
8. **Documentation.** Remove the limitation from known limitations, add the
   behavior to the shipped inventory and the binding guide, and delete this
   plan with the roadmap item. Test: `source-check`.

## Parallel work

Step 5 is one lane. Step 6 waits for it. Steps 7 and 8 follow in one lane.
One owner holds the shipped inventory and the limitation list. The decision is [ADR-0068](../decisions/adr/ADR-0068-promise-arguments.md).

## Questions for you

- Whether a received promise reaches a Zig actor as a capability, as this
  plan says, or as a distinct vow type. A capability keeps one way to send
  and listen across every surface.

## Where the code is

| Concern | Where |
| --- | --- |
| The lift | `src/driver/core/host/capabilities/lift.zig`, `liftValueInner` |
| Capability promise rows and verbs | `src/driver/core/capability_promise.zig`, `capability_promise/row.zig`, `capability_promise/answer.zig` |
| Inbound answer settlement and retention | `src/ocapn/session/answers/notifications.zig` |
| Session validation of the reference | `src/ocapn/session/validate/passable.zig` |
| Lowering values and vows | `src/driver/core/host/capabilities/lower.zig`, `src/driver/core/vows/settlement.zig` |
| Local promise projection for relayed promises | `src/ocapn/session/local_promise.zig` |
| Session limits | `src/ocapn/session/limits.zig` |
| The acceptance test | `test/driver/promise_argument_test.zig` |
| Fuzz corpus | `test/support/fuzz_program.zig` |
| C Host vow verbs | `src/c_abi/host/session.zig` |
| Live Goblins programs | `conformance/goblins-peer/racket/` |
| Pipelining decision | ADR-0003 |

| Steps | Gate |
| --- | --- |
| 8 | `source-check` |
| 5 | `test` on the driver and session layers, then `oracle-check` |
| 6 | the generated header and layout checks, then `runtime-check` |
| 7 | `check-external` |
