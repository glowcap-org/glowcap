---
type: static
description: How sleepy actors wake, schedule calls, and get evicted when Loam backs them on a Vat and Host.
audience: human
sources:
  - resource: /src/loam/hosting/
  - resource: /src/actors/
---

# Sleepy actors and durable hosting

A sleepy actor can drop its state from memory while its identity and the
references to it keep working. An eventual call wakes it first. Ordinary
actors still work without a store. The [API page](api.md)
covers store and attachment lifetimes.

Like the
[Goblins persistence tutorial](https://files.spritely.institute/docs/guile-goblins/0.17.0/Persistence-tutorial.html),
Loam keeps a behavior's description apart from its storage. Loam also makes
Zig borrowing, loading without blocking, and when a commit becomes visible
explicit.

## What is supported

The [Loam guide](../loam.md#durable-actors) shows how to use this on an
existing Host and Vat:

- Behavior backed by a record, with bounded waking, local capability fields,
  durable names that can be restored and retired, and replies that wait for
  the commit ([ADR-0163](../decisions/adr/ADR-0163-record-backed-sleepy-actors.md)).
  A stored record nobody references takes no endpoint. A held reference keeps
  only a little routing data, plus any state you pin.
- Calls that load the records they need and take part in transactions
  ([ADR-0169](../decisions/adr/ADR-0169-managed-host-turns.md)). A managed use
  endpoint is tied to one resource and its content, and a control prepares
  the edits it permits. When another commit lands first, the call prepares
  again, and it finishes any reads it submitted before releasing its state.
- Sharing one resource, with bounded receipts
  ([ADR-0170](../decisions/adr/ADR-0170-durable-facet-derivation.md)).
  Records are prepared on the Vat, the new durable name's entry is reserved
  when the Host finishes its turn, and the name works only after a confirmed
  commit.
- Capability arguments the call owns, and local capability edges returned
  through the Host and CapTP. Typed [local and remote fields](references.md)
  keep exactly the authority they saved and what restoring it depends on.
- Retiring a durable name through the attachment's write queue. Lookups stop
  once the retirement commits, stay stopped if the outcome is unknown, and
  come back if recovery shows the retirement never landed.
- Looking up a durable name only when a peer asks, which shares fetches
  through the same cache and restores the exact target without scanning or
  creating endpoints early
  ([ADR-0176](../decisions/adr/ADR-0176-on-demand-durable-publication-discovery.md)).

In-memory tests and a process test on each disk engine cover sleeping and
waking, cycles, cancellation, failed allocation, restart, reopen, and
recovery. The [managed process test](../../test/loam_managed_crash.zig)
covers grant issue, revocation, content changes, and removing references over
CapTP, with the process killed around the commit, around the Store taking it
in, and before the reply is sent.

Not supported: general narrowing of returned capabilities and durable outgoing
events. Timers, subscriptions, OS handles, and unresolved promises cannot be
saved, and waiting calls live only in memory. The [browser guide](browser.md)
covers the single-resource model in the browser.

## Identity, waking, and what stays alive

Loam keeps an in-memory entry only for an actor that is awake or being woken.
A sleeping object with no local or network references needs none. A held
reference keeps a little routing data and its own holds, not the target's
state or the graph it reaches. Durable names and stored edges keep their
targets alive by their own rules.

Loads are shared per object, per generation, and per Store. Callers that
arrive together share one wake, and their waiting messages count against the
existing per-source and per-owner limits. A load is taken in only if the
generation and revision are still current, so a deleted object, a replaced
owner, or a late load can never bring old state back. A storage failure is
different from a missing object and never creates a fresh actor. Retries pass
through the same limits.

Looking up a durable name also checks that the name is still published.
Retiring a name stops new lookups through it. It does not revoke references
already handed out or delete a target that something else keeps alive.

An actor's record names its behavior and schema versions, its stored fields,
and its reference edges. An unknown version cannot wake until a supported
upgrade runs. Waking keeps sharing and cycles intact without waking the whole
graph, and it runs none of the application's setup effects, such as sending
welcome messages or issuing new grants. Roots held across Vats must be in
place before collection can free anything during a restart, so restoring
Vats in a different order cannot lose edges.

## Calls and ordering

An eventual call to a sleeping actor keeps the call and asks your executor
for a load, while the Vat goes on with other work. When the load completes,
the call joins the Vat's existing queues, with no second ordering. Each call
source keeps the order it promises, including for messages that arrive while
the actor is going to sleep. Waiting calls and loads are counted against
their limits before any memory is allocated for them.

A near call cannot quietly wait on disk. Its fast path needs the target in
memory and pinned for the call, and an asynchronous acquire can bring it into
memory first. A near call to an actor on disk reports that the target must be
loaded, without running it. It never blocks, pauses a stack, or runs a caller
again that may already have had effects. Code that walks a large graph on
disk uses eventual calls or bounded prefetching.

Canceling a call ends the caller's interest in it, as usual. It does not
abandon a load in progress or a write that may have committed. When the last
waiter leaves, the operation is canceled only if the worker can show how it
ended. Pins and completion state stay charged until their owner can release
them. CapTP promise pipelining works as usual while an actor wakes and its
changes commit.

## Sleeping and when changes become visible

An actor may sleep once nothing borrows it and it is between turns. Its
current state must already be committed before Loam drops it, so a write that
is prepared or whose outcome is unknown keeps the actor awake. If the state
has not changed since the last commit, Loam can drop it with no new write,
so a read-only wake writes nothing. A call that races with sleeping either
finds the state still in memory or waits for the committed version to load,
and no call is lost.

Timers, pending promises, subscriptions, and outside handles each decide
explicitly whether the actor may sleep. Work owned by the runtime can outlive
the behavior if it targets a stable identity and keeps what it needs alive.
Otherwise it pins the state or keeps the actor awake. A stack, socket, or
borrowed pointer cannot be saved automatically. Putting an actor to sleep
frees its memory without running the application's delete or revoke code.

Saved changes become visible to anyone only after the transaction commits.
Replies that promise the change is saved, new durable names, and the matching
change events all wait for the commit. Change events saved with the change
carry sequence numbers and cursors, so they can be replayed and duplicates
dropped. When a call on disk resumes, and before a deferred reply hands out a
protected capability, Loam checks the grant as it is now. A cached copy of
the content or an earlier event never stands in for that check.

Sleeping does not mean a message was durably accepted, and waiting calls can
be lost if the process dies. A durable inbox or outbox would need its own
receipt and retry rules before Loam could promise that. A local snapshot never
takes back access that peers have already seen over the network. State kept
by a snapshot is charged on its own and can keep memory in use even after the
actor sleeps.

## Limits and what the tests must show

Two policies decide what sleeps: a byte-limited least-recently-used policy
over actors that may sleep, and a policy that puts every eligible actor to
sleep after each turn, for stress tests. Counting actors alone cannot bound
memory when actors differ in size, so payloads, bookkeeping, uncommitted
state, pins, wake queues, and engine memory are charged separately. Commits
and cleanup keep enough room to make progress when memory is tight. If
nothing can sleep, new calls are refused and the limit holds. Counters for
loads and sleeps, and the reason an actor cannot sleep, show where memory
went.

The tests must show:

1. The same near and far references keep working through repeated sleep and
   wake cycles, and saved references come back after a process restart.
2. Many calls to one sleeping actor wake it once. Slow reads, damaged records,
   cancellation, and a full cache never stall unrelated work on the Vat.
3. Near calls to an actor on disk never block or repeat effects. A pin keeps
   an actor awake until it is released, including through C and safe Rust
   borrows.
4. Grant edits, pauses, and revocations made while an actor is loading or
   preparing a reply still hold after waking, after a restart, and when
   reading an old version.
5. A crash around the commit of state, edges, grants, and events restores one
   consistent revision. An unknown outcome keeps its recovery owner and
   refuses unsafe use.
6. Cycles, roots across Vats, timers, promises, and subscriptions follow their
   declared rules for staying alive. Sleeping never deletes or revokes.
7. More objects on disk never means one in-memory actor per stored record.
   Measure the cost on the fast path, wake latency, extra writes, pinned
   memory, cache churn, and shutdown with operations still pending.

Run the same scenarios on the in-memory engine, on a disk engine with a
process restart, and in the browser. Sleep and wake latency and memory limits
need measurements, and one passing round trip through a reference is not
enough.
