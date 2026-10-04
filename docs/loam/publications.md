# Durable publication discovery

A publication gives a durable actor a secret name that peers can fetch, the
swiss number in a sturdyref. The name is saved on disk, so a sturdyref keeps
working after a restart. Nothing loads at startup; a fetch finds its name and
wakes only that actor. This is the publication and attachment-lifetime
contract for [Loam](../loam.md).

Register `hosting.publication.schema` with the Store and call
`publication.listen(attachment, options)` after opening it. One attachment
serves the Host's durable namespace. Startup creates no publication registry
rows or actor endpoints. A fetch looks up its name, reads the current descriptor
through the shared cache, and restores only its exact target. Concurrent fetches
of one name share the lookup and read. Explicit `publication.restore` remains
available when the embedding needs a resident registry entry.

Within an administrative transaction,
`publication.stage(attachment, entropy, held_target)` stores a rooted descriptor
and atomically indexes its secret name. The embedding supplies secure entropy.
Names are immutable and cannot be reassigned, even after retirement and collection.
Loam metadata format 3 requires this index and typed restoration edges;
recreate older prerelease stores.
This version is separate from LMDB's physical disk format.

Drive `Attachment.Work.lookup` through `backend.lookup` and return its result to
`attachment.completeLookup`, alongside the existing read/write work. Lookup
results carry store/incarnation/revision tickets; stale results retry. Default
limits permit 16 distinct pending names and 64 fetches, with explicit refusal
at capacity. Registration allocates the owner and two bounded arrays. A group
retains 16 secret bytes; submitted work retains custody even if every requester
leaves. Each indexed name retains 58 logical bytes before backend overhead;
collection preserves this reservation while reclaiming the descriptor.

To retire discovery, load the current descriptor, begin a transaction, call
`stageRetirement`, and submit through `attachment.submit`. Its normal write lane
owns the commit-to-registry transition. Unknown outcomes fail closed; recovery
restores discovery only if the retirement did not commit. A proven-absent batch
settles its write outcome before restoration can allocate. Previously resident
publication names retain bounded retirement custody until ordinary `advance`
restores them. Cold reads use the existing read lane; allocation or capacity
refusal preserves the retry. Later transactions and recovery cannot discard or
block this custody. Retries run while the Store is idle, after ordinary calls
release settlement leases. Previously cold names remain on-demand and create no
registry row. Current-authority checks prevent stale lookups from resurrecting
retired publications. Retirement preserves held
references and only removes discovery. Rooted descriptors retain their target
across restart; raw object IDs alone retain nothing.

Drain pending calls and storage operations before `attachment.destroy()`;
it returns `Busy` while calls, reads, writes or deferred publication restoration
remain. Destruction closes the attachment to
future calls. Existing capabilities retain closed routing metadata until their
Host/Vat custody ends and receive `AttachmentClosed`; they do not access the
Store afterward. Destroy the attachment before deinitializing Store or Host.
The attachment pointer must not be used after destruction succeeds.


The boundary and alternatives are recorded in
[ADR-0176](../decisions/adr/ADR-0176-on-demand-durable-publication-discovery.md).
