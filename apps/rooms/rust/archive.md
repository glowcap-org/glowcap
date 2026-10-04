# The member archive

A member's history belongs to the member. The room server keeps a room's
lines because the room belongs to the server. A direct line's history is kept
by its reader, because only the reader's browser ever sees its plaintext.

So Rooms gives each member one ordinary OCapN object for what they kept. One
Rust design implements it in three places:

- in the browser, over IndexedDB;
- in the archive service, over a journal on disk;
- inside the session service, for the history a durable session records.

This page describes that design. [Operating Rooms](../operating.md) explains
how to run the archive service. These decision records hold the details:
[ADR-0129](../../../docs/decisions/adr/ADR-0129-member-owned-archive-capability.md),
[ADR-0130](../../../docs/decisions/adr/ADR-0130-durable-member-archive-peer.md),
[ADR-0132](../../../docs/decisions/adr/ADR-0132-monotonic-archive-facets-and-direct-handover.md),
[ADR-0136](../../../docs/decisions/adr/ADR-0136-archive-attachment-custody.md),
[ADR-0140](../../../docs/decisions/adr/ADR-0140-rooms-archive-share-authority.md),
and [ADR-0144](../../../docs/decisions/adr/ADR-0144-combined-archive-views.md)
record the decisions.

## The object

- `put(record)` inserts or replaces one line or one standing.
- `read(filter, afterRevision, limit)` returns a page of at most 128 records
  in revision order.
- `narrow(filter, access)` returns a facet whose scope can only shrink and
  whose write authority can only be removed. A narrowed facet also loses the
  authority to issue shares.
- `attachment` and `blob` return bounded readers for the bytes a record
  names.
- A trusted owner can `clear` the whole account. No facet offers an erase
  verb.
- `share`, `revokeShare`, and `shares` are answered only by the whole-archive
  root of a service that keeps durable shares.

The code is split by layer:

- `application::archive` holds the portable policy: records, filters, facet
  scope, wire tuples, the revision index, and bounded remote scans. It
  compiles unchanged for the services and the browser.
- `glowcap::archive` turns records into the binding's passable values.
- `client::archive::Archive` holds a real archive capability and calls its
  verbs with deadlines.
- `runtime::archive` hosts the verbs, through one serial worker per archive,
  over a `Backend` that commits storage and a `Source` that reads bounded
  file chunks.

## Records and identity

A record's identity is its recorder source, its conversation generation,
its record kind, its conversation kind, its directory, its conversation, and
its record id. Reusing a line id in another room, directory, or generation
cannot replace its sibling. Neither the source nor the generation is a
person: a nickname and a fresh session key cannot merge records. Replacing a
line keeps its first timestamp and its place in the conversation's order.

The index keeps the most recently revised records, up to 5,000, and reads at
most 128 rows per page. Records are shared immutably between the identity
and revision maps, so a lookup borrows fields without building a key and a
held page keeps its values across replacement and eviction. Restoring an
invalid snapshot leaves the current index untouched, and clearing content
keeps the revision high-water mark. A remote scan counts every received row,
refuses a feed past 5,000, keeps the latest revision per identity, and
exposes results only after a terminal page.

Text is kept the way it was written: ordinary text as UTF-8, and an isolated
UTF-16 surrogate as its exact code units in the version-one JSONL codec.
Only the outgoing wire projection applies the replacement a `TextEncoder`
would.

## The file backend

`services::archive::file::FileArchive` owns the record journal, the blob
directory, and an exclusive lease on the state directory. Startup validates
snapshot order, identities, and revision continuity before publishing an
index. A torn final line is repaired durably before serving; a corrupt
complete line refuses startup without rewriting the file. Append and fsync
precede index publication and the reply. Compaction replaces the file
atomically with file and directory synchronization, keeping the prior index
until the new one is committed. A write whose outcome is uncertain retires
the backend until it is reopened and recovered.

The default bounds are 5,000 records, 512 extra journal rows before
compaction, and 128 MiB per file. Parsing, indexing, and filesystem work run
on a blocking worker; records cross that boundary shared, not copied. A
cancelled observation leaves the job owned, and a later operation observes
its result first. Session documents use the same lock, read, and atomic
replacement owner with their own codec and filenames.

## Files

The blob owner names content by SHA-256, shares repeated content, and
applies reference changes only after the journal commits. It keeps at most
512 MiB, with at most one 64 MiB file of staging beyond that. A file put
streams exact chunks to the disk worker through a single slot: at most one
chunk is queued, one being written, and one being fetched, and no whole file
is assembled. Waiting for a slow source happens before the backend is asked
to store anything, so every other operation keeps its place in the queue. An
erasure refuses every put whose bytes are still arriving; a capture cut short
by shutdown is refused rather than left unanswered.

A reader is bounded by the issued scope, the exact record address, the file
position, and the expected digest, and every read rechecks the current
record: replacement or removal of the digest disables an old reader. Each
caller session may mint at most 512 readers over its life across every
facet. Startup prunes orphans, a retained file is checked for size and
digest on its first read, missing or corrupt bytes refuse the read, and
uploading matching content again repairs a corrupt blob.

## Shares

A share is an independently revocable sturdyref onto some scope of the
archive. The version-one `shares.json` keeps issuance order, exact UTF-16
text, the HMAC-derived entropy, at most 32 active shares and 256 lifetime
identities. Retrying the same share is idempotent; a conflicting or revoked
identity refuses reuse. The ledger is published only after atomic
replacement is durable, and an uncertain outcome disables storage until
reopen.

Only the whole-archive root of a service can issue shares.

- Each published share carries a revocation guard through every narrowed
  facet and reader. Admission checks the guard, and queued work checks it
  again before calling the backend. So a read ordered before a revocation may
  complete, and one queued behind it is refused.
- A share is published only after it is durably committed. If publishing
  fails, the exact names are kept for a retry, and the committed share is
  never rolled back.
- An orderly close revokes descendants, removes publications, and reports
  cleanup failures separately.

## Recording in a session

`runtime::session_archive` owns what a durable session records: the
selected archive (the browser store, the session's own archive, or a chosen
peer), ordered local recording, shares, and erasure. Its queue admits 64
requests holding at most 2 MiB of input and 64 MiB of named file bytes.
Selection takes effect between operations; a failed selected peer stays
unavailable rather than redirecting writes to the browser, so a member
never has a second history they did not choose. Reads merge every archive
the member holds, comparing full record identity, then withdrawal and edit
state, then the current writer, then listed order, and cloning only the
winning record handles.

Recording policy chooses durable messages, keeps line coordinates, maps
edits and refiles onto the edited row, and removes text and files on
withdrawal. System messages, typing, and messages without a line identity
produce no record. A line and its room standing are admitted as one
operation, so selection or erasure cannot separate them.

Files are captured at admission, alongside the queue, within a 64 MiB pending
budget and 32 active captures. When either limit is full, or the selected
backend keeps no bytes, the record keeps the file's metadata and notes that
its bytes were not kept, and the completion says which case applied.

Turning history off obliges the session to erase it. The checkpoint that
disables history records that intent, so it can be recovered. The erase runs
through the same queue with a fair share of its capacity, and no later
checkpoint may reach disk until the erase has finished. If the process stops
first, the next start clears what remains before reporting ready.

## Evidence

`zig build rooms-archive-test` proves the archive contract, the bounded
store, the wire path, and a process restart against the Rooms clients.
`zig build rooms-peers-test` proves the archive service's identity, restart,
and signal shutdown. The contract proofs under `proofs/` replay the record and
filter parsers, the journal loader, the share ledger, the merge, and the
recorder from fixtures, both natively and in Wasm. `test/store/` under
`apps/rooms` holds the browser store to the same contract.
