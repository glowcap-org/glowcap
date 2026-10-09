# Observing managed access

Status: living-state surface. This guide owns observation registration,
receiver custody, scoped cursors and cancellation for managed access.
The [managed access guide](access.md) owns use/control and mutation admission.

Call `mutate(sequence, "observe")` on a managed use or control endpoint to
register observation of its exact descriptor. The two-item result contains a
receiver and an independent canceller. Registration shares the endpoint's eight
mutation receipts: retrying the exact request recovers the same fronts without
creating another context. Set `Service.entropy.fill` before registration.
Runtime dependent facets do not accept this fixed-descriptor method.

Runtime consumers register with `mutate(sequence, "observe-live", identity)`.
The identity is sixteen opaque bytes retained with the original request; it
distinguishes concurrent callers that discover the same next sequence. Only
`OperationConflict`, which proves that another request owns the sequence,
permits discovering a new sequence. A lost answer retains the original request.
The hosting attachment must have a confirmed live scope. Its saved marker
revision fences these receivers: advancing the marker on restart closes them.
Each new runtime registration reclaims one expired context belonging to that
marker, clearing its authority and retiring its publications in the same
transaction that installs the replacement. The bounded index can therefore
recover from an unclean end even when every slot was occupied. Durable
registrations retain their original restart contract.

Paused use can discover `mutation-sequence()` and register a fresh observer.
Its exact `durable-name()` also remains available, so reopening a paused view
does not require content use. These metadata calls still refuse revoked access
and scope loss. Ordinary content calls remain subject to active admission.

The receiver accepts `poll()` or `receive()`, optionally with the last cursor as
one bytes argument. `poll` returns the current result; `receive` waits when that
cursor is unchanged. The tagged `access:observation` reply contains, in order:
a 56-byte cursor, the existing scoped use or control description, a
resynchronization Boolean, a changed Boolean, and a list of notice symbols.
The notice categories are `access`, `target`, `inventory`, and `management`.
They describe retained changes; delivery can coalesce several committed batches
with the current authorized snapshot. A snapshot does not authorize a later call.

The cursor binds one context and carries no authority by itself. Keep the
receiver's durable name and cursor to resume after disconnect or restart.
Hidden sibling commits preserve the cursor, including when requesting a fresh
snapshot without an input cursor. Expired visible history sets resynchronization
and supplies the current snapshot. Paused use discloses status alone; policy or
content edits while paused do not perturb its cursor. Revoked use and unavailable
controls likewise disclose status alone. Delivery rechecks current authority
through the same evaluator and Store revision fence as ordinary calls.

Call `cancel()` on the canceller to close the context. It atomically removes the
owner's retention edge, clears the context's source edges and sealing key, and
retires both durable names. A held canceller returns false after closure; an
exact registration retry refuses instead of reminting the closed context.
Cancellation can run while its receiver waits. Abort preserves the context and
names; uncertain writes use the ordinary recovery and retirement fences.

Each owner admits at most 32 contexts. Cancellation frees that quota. Each
context retains its exact descriptor and optional fixed resource identity, with
a 32-byte unpredictable sealing key and an immutable registration boundary.
Grant and resource dependency stamps pair their revision with the corresponding
committed batch position. The cursor seals only the relevant scoped position
and digest using Zig's AES-128-SIV implementation, with the context identity as
associated data. Neither raw revisions nor owner counters appear on the wire.
[ADR-0179](../decisions/adr/ADR-0179-scoped-change-retention-and-observation.md)
owns retention, privacy and replay.

Zig consumers use opaque `storage.ObservationRegistration`,
`storage.Observation`, and `storage.ObservationCancellation` operations.
Registration borrows an unprepared source `Operation`, takes a target for use
or null for control and an embedding-supplied key, and stages into the caller's
Store transaction. Drive missing source reads before retrying construction,
then drive the registration's reads. Its child custody prevents the source from
closing early. Polling starts from a committed context lease and returns owned
bounded values. Cancellation also starts from a context lease and stages in the
caller's transaction. Published contexts require the hosting retirement bridge;
a Zig caller cannot silently leave their names active. Cancel submitted reads
and join their exact completions before releasing operations.

Record-binding, cache, lease, retention, call-arena, ingress and transport limits
remain independent. Parked hosted receivers release managed operations and model
leases. Ready replies release them after copying their snapshots; Attachment
rechecks the revision before delivery. The maximum-fanout test admits 32 cold
receivers with eight model bindings per call, 296 leases, 80 cache slots, a 5 MiB
resident budget, 168 retention slots, 4 MiB ingress capacity and a 128 KiB
outbound waterline at a 4 KiB frame cap. Smaller budgets refuse explicitly;
32 context slots alone do not promise 32 simultaneous cold calls. Deep paths
need larger binding budgets within the same bounded operations.
