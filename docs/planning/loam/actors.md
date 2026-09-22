# Sleepy actors and durable hosting

Status: active plan. This contract owns actor activation, call scheduling,
eviction, and their acceptance tests for Loam integration with the existing
Vat and Host. The [Loam architecture](architecture.md) owns placement and
implementation order; the [API contract](api.md) owns store and attachment
lifetimes. The [planning guide](../README.md) maps the complete design.

Persistence-enabled actors can release their resident behavior state while
retaining their identity and callable references. An eventual send wakes a
sleeping target before execution. This is a required part of the first durable
actor integration, not an optimization deferred until after Rooms adopts it.
Ordinary volatile actors remain supported without a store.

The [Goblins persistence tutorial](https://files.spritely.institute/docs/guile-goblins/0.17.0/Persistence-tutorial.html)
separates reconstructible behavior descriptions from storage and supports vats
and lower-level actormaps. Follow that separation while making Zig borrowing,
nonblocking loading, and commit visibility explicit. The contracts below are
glowcap design requirements, not claims about Goblins' implementation.

## Implemented profile and remaining contract

The [Loam usage guide](../../loam.md#durable-actors) and
[ADR-0163](../../decisions/adr/ADR-0163-record-backed-sleepy-actors.md) describe
the first implementation: explicit record-backed behavior, bounded activation,
local capability fields, publication restoration/retirement, and commit-gated
replies on an existing Host/Vat. Volatile tests and a native LMDB process proof
cover sleep/wake, cycles, cancellation, allocation refusal, and restart.
Unreferenced cold records create no endpoint; held references retain only
bounded routing metadata and any explicitly pinned state.

[ADR-0169](../../decisions/adr/ADR-0169-managed-host-turns.md) extends that same
attachment with call-owned working-set preparation and transaction participants.
Managed use endpoints authorize a fixed resource/content binding; controls
prepare permitted edits. Preparation restarts after intervening commits and
retires submitted reads before releasing its state. Native reopen/recovery
tests cover this extension; the existing process-kill proof covers the ordinary
record-backed actor profile.

[ADR-0170](../../decisions/adr/ADR-0170-durable-facet-derivation.md) adds
fixed-resource derivation and bounded receipts. The same attachment stages
records in the Vat, reserves hidden publication custody at the top-level Host
boundary, and activates it only after confirmed commit.

The full contract below remains the destination. This profile accepts plain
request arguments and returns local capability edges through Host/CapTP;
it does not yet support foreign fields, general returned-capability attenuation, durable event
intentions, browser storage, cross-vat roots, or foreign
language borrow APIs. Administrative publication retirement through the attachment's
write lane applies discovery removal at the commit outcome, fails closed on
unknown outcomes, and re-publishes when recovery proves the batch absent.
Timers, subscriptions, native handles, and unresolved promises have no durable
representation here. Pending calls are volatile. Workload and tail-latency
measurements remain required; functional tests do not establish the scale goal.

## Identity, activation, and retention

Resident actor entries track active state or a pending activation. Sleeping
objects without live local or wire references need no resident entry. Existing
held references retain bounded routing/custody metadata, not the target's
entire state or reachable graph. Durable publications and stored reference
edges retain their targets according to their own lifecycle contracts.

Loading is coalesced per object identity, generation, and store incarnation.
Concurrent callers share one activation, with their waiting messages charged
to existing ingress and owner budgets. Completion installs state only after
validating the current generation and revision. Deleted objects, replaced
owners, and late completions cannot resurrect state. A publication lookup also
rechecks whether the publication remains active. Retiring a publication blocks
new lookup through that name; it does not revoke previously issued references
or delete a target retained through another edge.
Storage failure is distinguishable from missing identity and never creates a
fresh actor as a fallback. Retries pass through the same admission limits.

The reconstruction descriptor identifies behavior and schema versions, its
stored fields, and its reference edges. Unknown versions refuse activation
until an explicit supported upgrade runs. Reconstruction preserves sharing and
cycles without recursively waking the graph. It performs no application
initialization effects such as sending welcome messages or minting new grants.
Cross-vat retained roots must be established before collection can reclaim
objects during restart; restoring vats in a different order cannot lose edges.

## Calls and scheduling

An eventual send to a sleeping actor retains admitted work and requests a load
through the existing embedding executor. The Vat continues unrelated runnable
work. Wake completion makes the admitted delivery runnable through existing
queues; it does not create a second scheduling order. Preserve the ordering
already promised by each ingress, including messages arriving during eviction.
Bound pending activations and waiters before allocating their state.

A synchronous near call cannot transparently perform asynchronous disk I/O.
Its fast path requires a resident target pinned for the call. Explicit
asynchronous acquisition can establish that residency before entering the
synchronous operation. A cold synchronous call reports a residency requirement
without running the cold callee. It never secretly blocks, suspends a native
stack, or replays a caller that may already have produced effects. Code that
traverses an unbounded cold graph uses eventual operations or bounded prefetch.

Cancellation retires the observer's interest under existing call semantics.
It does not discard ownership of a running load or a possibly committed write.
The final waiter leaving permits cancellation only when the adapter can prove
the operation's terminal outcome. Pins and completion state stay charged until
their owner can release them. CapTP promise pipelining uses existing promise
and reference machinery throughout activation and commitment.

## Eviction and durable visibility

An actor becomes eligible to sleep at a safe execution boundary after active
borrows end. Its current state must have a committed reconstruction record
before that state is released. A prepared or uncertain write cannot be treated
as clean state. Eviction can reuse an unchanged committed version; a read-only
wake need not produce a new write. New calls racing eviction either retain the
resident state or wait for its committed version to load, with no lost delivery.

Sleep eligibility is explicit for timers, pending promises, subscriptions, and
external handles. A runtime-owned continuation may survive outside the behavior
if it targets stable identity and preserves required retention. Otherwise it
pins the state or makes the actor ineligible. A native stack, socket, or borrowed
pointer has no automatic durable representation. Eviction cleanup releases
resident allocations without invoking application deletion or revocation.

Durable state changes become externally visible only after the selected
transaction commits. Replies promising durability, new capability publication,
and corresponding events wait for that acknowledgement. Persist recoverable
event intentions with the change; sequence/cursor handling permits replay and
deduplication. A changed grant is checked from current authority when a cold
call resumes and before a deferred protected disclosure. A cached content
snapshot or an earlier event cannot substitute for that decision.

Sleep does not imply durable message acceptance. The first integration must
state which pending calls can be lost on process failure. Durable inboxes and
outbound intentions require their own receipt and retry contract before that
stronger guarantee is exposed. Local snapshots never rewind authority already
observed through the network. Snapshot-retained state is separately charged
and can prevent physical RAM reclamation even after a live actor sleeps.

## Budgets and proof obligations

Start with a byte-budgeted least-recently-used policy over eligible actors and
an every-eligible-turn policy for stress testing. Count-based limits alone do
not bound memory when actors differ in size. Charge payload, metadata, dirty
state, pins, activation queues, and backend residency separately. Maintain
commit/cleanup progress capacity under pressure; if nothing can be evicted,
apply bounded admission refusal rather than exceed the budget. Expose reasons
for ineligibility and load/eviction counters so retained state is diagnosable.

The acceptance suite must demonstrate:

1. The same held near and far references work through repeated sleep/wake cycles;
   supported durable references recover after process restart.
2. Many sends to one cold target produce one activation. Slow reads, corrupt
   records, cancellation, and a full cache preserve unrelated Vat progress.
3. Cold synchronous calls never block or replay effects. Explicit pins prevent
   eviction until release, including C and safe Rust borrow lifetimes.
4. Grant edits, pauses, and revocations during loading or reply preparation
   remain effective after wake, restart, and snapshot access.
5. Crashes around state/edge/grant/event commitment restore one consistent
   revision. Unknown outcomes retain their recovery owner and refuse unsafe use.
6. Cycles, cross-vat roots, timers, promises, and subscriptions obey their
   declared retention policy; sleep never acts as deletion or revocation.
7. Increasing cold object count does not allocate one resident actor per stored
   record. Measure hot-path overhead, wake latency, dirty-write amplification,
   pinned memory, cache thrashing, and shutdown with operations pending.

Run the same semantic scenarios through a volatile test store, a real native
store with process restart, and the browser adapter. Sleep/wake latency and
memory bounds need measurements; passing a reference round-trip is insufficient.
