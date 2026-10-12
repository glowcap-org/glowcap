# Durable names

A publication gives a durable actor a secret name that peers can fetch, the
swiss number in a sturdyref. The name is saved on disk, so a sturdyref keeps
working after a restart. Nothing loads at startup. A fetch finds its name and
wakes only that actor. This is the publication and attachment-lifetime
contract for [Loam](../loam.md).

## Serving names

Register `hosting.publication.schema` with the Store and call
`publication.listen(attachment, options)` after opening it. One attachment
serves the Host's durable namespace. Startup creates no publication registry
rows or actor endpoints. A fetch looks up its name, reads the current descriptor
through the shared cache, and restores only its exact target. Concurrent fetches
of one name share the lookup and read. Explicit `publication.restore` remains
available when the embedding needs a resident registry entry.

## Publishing a name

Within an administrative transaction,
`publication.stage(attachment, entropy, held_target)` stores a rooted descriptor
and atomically indexes its secret name. The embedding supplies secure entropy.
Names are immutable and cannot be reassigned, even after retirement and collection.
Loam metadata format 3 requires this index and typed restoration edges, and
older stores need recreating. This version is separate from LMDB's physical
disk format.

## The lookup work item

Drive `Attachment.Work.lookup` through `backend.lookup` and return its result to
`attachment.completeLookup`, alongside the read and write work. Lookup
results carry store/incarnation/revision tickets. Stale results retry. Default
limits permit 16 distinct pending names and 64 fetches, with explicit refusal
at capacity. Registration allocates the owner and two bounded arrays. A group
retains 16 secret bytes. Submitted work retains custody even if every requester
leaves. Each indexed name retains 58 logical bytes before backend overhead.
Collection preserves this reservation while reclaiming the descriptor.

## Retiring a name

To stop a name from answering fetches, load the current descriptor, begin a
transaction, call `stageRetirement`, and submit through `attachment.submit`.
Fetches stop finding the name once the retirement is submitted. The
attachment's write lane owns the step from commit to registry, and an aborted
retirement brings discovery back.

Retirement removes discovery only. References peers already hold keep
working, and a rooted descriptor keeps its target alive across a restart. A
raw object ID on its own keeps nothing alive.

An unknown write outcome fails closed: the name stays retired unless recovery
proves the retirement never committed. A batch proven absent settles its
write outcome before restoring the name can allocate anything.

When discovery comes back for a name that was resident, the name keeps
bounded retirement custody until an ordinary `advance` restores it. Cold reads
go through the read lane, and an allocation or capacity refusal keeps the retry.
Later transactions and recovery can neither discard nor block that custody.
Retries run while the Store is idle, after ordinary calls release their
settlement leases. A name that was cold stays on demand and creates no
registry row. Current-authority checks stop a stale lookup from bringing a
retired name back.

## Destroying the attachment

Drain pending calls and storage operations before `attachment.destroy()`. It
returns `Busy` while calls, reads, writes or deferred publication restoration
remain. Destruction closes the attachment to future calls. Existing capabilities
retain closed routing metadata until their Host/Vat custody ends and receive
`AttachmentClosed`. They do not access the Store afterward. Destroy the
attachment before deinitializing Store or Host. The attachment pointer must not
be used after destruction succeeds.

The boundary and alternatives are recorded in
[ADR-0176](../decisions/adr/ADR-0176-on-demand-durable-publication-discovery.md).
