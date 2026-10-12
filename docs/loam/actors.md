# Sleepy actors and durable hosting

This contract owns actor activation, call scheduling, and eviction for Loam's
integration with the Vat and Host. The [API contract](api.md) owns
store and attachment lifetimes.

A sleepy actor can release its state from memory while keeping its identity and
callable references. An eventual send wakes it first. Ordinary actors still
work without a store.

Like the
[Goblins persistence tutorial](https://files.spritely.institute/docs/guile-goblins/0.17.0/Persistence-tutorial.html),
Loam separates a behavior's description from its storage. Loam also makes Zig
borrowing, nonblocking loading, and commit visibility explicit.

## Implemented profile

The [Loam usage guide](../loam.md#durable-actors) shows how to use what is
implemented today on an existing Host and Vat:

- Record-backed behavior with bounded activation, local capability fields,
  publication restoration and retirement, and replies that wait for commit
  ([ADR-0163](../decisions/adr/ADR-0163-record-backed-sleepy-actors.md)).
  Unreferenced cold records create no endpoint. Held references keep only
  bounded routing metadata and any explicitly pinned state.
- Call-owned working-set preparation and transaction participants
  ([ADR-0169](../decisions/adr/ADR-0169-managed-host-turns.md)). Managed use
  endpoints authorize a fixed resource and content binding. Controls prepare
  permitted edits. Preparation restarts after intervening commits and retires
  submitted reads before releasing its state.
- Fixed-resource derivation and bounded receipts
  ([ADR-0170](../decisions/adr/ADR-0170-durable-facet-derivation.md)). Records
  stage in the Vat, publication custody is reserved at the top-level Host
  boundary, and it activates only after confirmed commit.
- Owned capability arguments, and local capability edges returned through
  Host and CapTP. Typed [local and foreign fields](references.md) keep exact
  authority and restoration dependencies.
- Publication retirement through the attachment's write lane. Discovery is
  removed at the commit outcome, fails closed on an unknown outcome, and comes
  back when recovery proves the batch absent.
- Opt-in cold publication lookup, which coalesces fetches through the same
  cache and restores exact targets without scanning or creating endpoints
  early ([ADR-0176](../decisions/adr/ADR-0176-on-demand-durable-publication-discovery.md)).

Volatile tests and an LMDB process proof cover sleep and wake, cycles,
cancellation, allocation refusal, restart, and reopen and recovery. The
[managed process proof](../../test/loam_managed_crash.zig) covers issuance,
revocation, content changes, and reference removal through CapTP across
commit, local installation, and undelivered-reply boundaries.

Not supported here: general attenuation of returned capabilities, durable
event intentions, and borrow APIs in other languages. Timers, subscriptions,
operating-system handles, and unresolved promises have no durable form, and
pending calls are volatile. Browser fixed-resource execution has its own
[consumer profile](browser.md). Workload and tail-latency measurements are still
required, because functional tests do not show the scale goal is met.

## Identity, activation, and retention

Resident actor entries track active state or a pending activation. Sleeping
objects without live local or wire references need no resident entry. Held
references retain bounded routing and custody metadata and not the target's
state or reachable graph. Durable publications and stored reference
edges retain their targets according to their own lifecycle contracts.

Loading is coalesced per object identity, generation, and store incarnation.
Concurrent callers share one activation, with their waiting messages charged
to existing ingress and owner budgets. Completion installs state only after
validating the current generation and revision. Deleted objects, replaced
owners, and late completions cannot resurrect state. A publication lookup also
rechecks whether the publication remains active. Retiring a publication blocks
new lookup through that name. It does not revoke previously issued references
or delete a target retained through another edge.
Storage failure is distinct from missing identity and never creates a fresh
actor. Retries pass through the same admission limits.

The reconstruction descriptor identifies behavior and schema versions, its
stored fields, and its reference edges. Unknown versions refuse activation
until an explicit supported upgrade runs. Reconstruction preserves sharing and
cycles without recursively waking the graph. It performs no application
initialization effects such as sending welcome messages or minting new grants.
Cross-vat retained roots must be established before collection can reclaim
objects during restart. Restoring vats in a different order cannot lose edges.

## Calls and scheduling

An eventual send to a sleeping actor retains admitted work and requests a load
through the embedding executor. The Vat continues unrelated runnable work. Wake
completion makes the admitted delivery runnable through existing queues, with no
second scheduling order. The ordering each ingress promises holds, including
for messages arriving during eviction. Pending activations and waiters are
bounded before their state is allocated.

A synchronous near call cannot transparently perform asynchronous disk I/O. Its
fast path requires a resident target pinned for the call. Explicit asynchronous
acquisition can establish that residency before entering the synchronous
operation. A cold synchronous call reports a residency requirement without
running the cold callee. It never blocks, suspends a stack, or replays a caller
that may already have produced effects. Code that traverses an unbounded cold
graph uses eventual operations or bounded prefetch.

Cancellation retires the observer's interest under existing call semantics.
It does not discard ownership of a running load or a possibly committed write.
The final waiter leaving permits cancellation only when the adapter can prove
the operation's terminal outcome. Pins and completion state stay charged until
their owner can release them. CapTP promise pipelining uses the promise and
reference machinery throughout activation and commitment.

## Eviction and durable visibility

An actor becomes eligible to sleep at a safe execution boundary after active
borrows end. Its current state must have a committed reconstruction record
before that state is released. A prepared or uncertain write cannot be treated
as clean state. Eviction can reuse an unchanged committed version. A read-only
wake need not produce a new write. New calls racing eviction either retain the
resident state or wait for its committed version to load, with no lost delivery.

Sleep eligibility is explicit for timers, pending promises, subscriptions, and
external handles. A runtime-owned continuation may survive outside the behavior
if it targets stable identity and preserves required retention. Otherwise it
pins the state or makes the actor ineligible. A stack, socket, or borrowed
pointer has no automatic durable representation. Eviction cleanup releases
resident allocations without invoking application deletion or revocation.

Durable state changes become externally visible only after the selected
transaction commits. Replies promising durability, new capability publication,
and corresponding events wait for that acknowledgement. Recoverable event
intentions persist with the change, and sequence and cursor handling permits
replay and deduplication. A changed grant is checked from current authority when
a cold call resumes and before a deferred protected disclosure. A cached content
snapshot or an earlier event cannot substitute for that decision.

Sleep does not imply durable message acceptance, and pending calls can be lost
on process failure. Durable inboxes and outbound intentions need their own
receipt and retry contract before that stronger guarantee is exposed. Local
snapshots never rewind authority already observed through the network.
Snapshot-retained state is separately charged and can prevent physical RAM
reclamation even after a live actor sleeps.

## Budgets and proof obligations

The policies are a byte-budgeted least-recently-used policy over eligible actors
and an every-eligible-turn policy for stress testing. Count-based limits alone
do not bound memory when actors differ in size, so payload, metadata, dirty
state, pins, activation queues, and backend residency are charged separately.
Commit and cleanup keep progress capacity under pressure. If nothing can be
evicted, bounded admission refusal applies and the budget holds. Reasons for
ineligibility and load and eviction counters keep retained state diagnosable.

The acceptance suite must demonstrate:

1. The same held near and far references work through repeated sleep/wake cycles.
   Supported durable references recover after process restart.
2. Many sends to one cold target produce one activation. Slow reads, corrupt
   records, cancellation, and a full cache preserve unrelated Vat progress.
3. Cold synchronous calls never block or replay effects. Explicit pins prevent
   eviction until release, including C and safe Rust borrow lifetimes.
4. Grant edits, pauses, and revocations during loading or reply preparation
   remain effective after wake, restart, and snapshot access.
5. Crashes around state/edge/grant/event commitment restore one consistent
   revision. Unknown outcomes retain their recovery owner and refuse unsafe use.
6. Cycles, cross-vat roots, timers, promises, and subscriptions obey their
   declared retention policy. Sleep never acts as deletion or revocation.
7. Increasing cold object count does not allocate one resident actor per stored
   record. Measure hot-path overhead, wake latency, dirty-write amplification,
   pinned memory, cache thrashing, and shutdown with operations pending.

Run the same scenarios through a volatile test store, a durable store with
process restart, and the browser adapter. Sleep and wake latency and memory
bounds need measurements, and a passing reference round trip is insufficient.
