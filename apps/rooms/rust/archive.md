# Rooms archive migration

The portable `application::archive` module owns validated records, filters,
monotonic facet scope, wire tuples, revision indexing and bounded remote scans.
It compiles unchanged for native and browser Wasm. `glowcap::archive` builds the
existing binding's passables; `client::archive::Archive` holds a real capability
and executes `put`, `read`, `narrow` and complete history scans with deadlines.
Shared `runtime::archive` executes record and live-facet methods through an
owned backend worker on native and Wasm. A native record journal implements that backend;
native file custody retains content-addressed bytes. The standalone archive
service runs Rust, including durable shares and identity. The native session
peer records kept history into a session-owned archive and answers the
archive-share verbs; [operating](../operating.md) describes that peer. All session
process scenarios launch the native executable. React and its TypeScript
adapters retain the browser presentation and intent boundary; the application
session owner runs in Rust Wasm.

Record identity includes recorder source, generation, record kind, conversation
kind, directory, conversation and record ID. Reusing a line ID in another room,
directory or generation cannot replace its sibling. Replacing a line preserves
its first timestamp and conversation order. The index keeps the most recently
revised records, up to 5,000, and reads at most 128 rows per page. Restoring an
invalid snapshot leaves the current index untouched. Clearing content preserves
the revision high-water mark.

The index accepts owned, validated records after storage commitment. Its ordered
identity and revision maps share immutable records through `Arc`; identity lookup
borrows record fields without creating string keys. Held pages retain their
original record values across replacement and eviction. They are caller-owned
custody, so index capacity alone is not a bound on all application retention.
The production owner must bound its queued and handed-out work separately.
Wire parsing borrows the binding's decoded rows and materializes only bounded
record fields. Output builds binding arguments directly, without another
production passable representation. Temporary outgoing arguments end after
send admission, before awaiting the reply.

A complete remote scan counts all received rows, including repeated revisions
of the same identity. It refuses feeds exceeding 5,000 rows, retains the latest
entry per identity, and exposes results only after a terminal page. Replacement
removes the old map key as well as its value, releasing superseded text when no
other caller owns it. Narrowing intersects every scope dimension and cannot
upgrade read access to write access.

Two stricter behaviors are intentional. Reading with a cursor ahead of the
index returns that cursor without regression; the TypeScript index could
produce a page its outer validator refused. A successful `put` must acknowledge
a positive revision, matching the hosted contract; the old client accepted zero.

`proofs/fixtures/archive.json` captures the historical TypeScript record/filter
parser and renderer. Native and Wasm proofs replay that capture and exercise
identity isolation, chronology, eviction, restoration, scope, malformed pages,
capability refusal and bounded scans. Native TCP tests exercise real client
calls, returned facets, malformed replies and a feed that revises one identity
forever. The in-memory hosted actor in that test is a fixture.

`runtime::archive` hosts put/read/narrow through shared method admission. Its
serial worker owns the backend and keeps record reads behind earlier accepted
writes. A file put's bytes are captured from the caller beside that queue, up
to 32 puts and 64 MiB of declared bytes at once, and stored when the last byte
lands, so one caller's slow source holds only its own put. The queue admits 64
operations within 2 MiB of retained input, charged through reply settlement. Empty scope intersections answer synchronously without storage.
The non-Clone parent provides weak hosted producers; dropping it stops admission.
Orderly close drains accepted work, and cancelling a close observation leaves
that worker running. Worker retirement cannot report completed shutdown. Neither
path closes the shared transport sessions.

Live facets share an issuer per archive owner. Every actual caller session gets
256 nonrefundable lifetime mints across the root and all descendants. Closed
caller accounts are pruned on issuance; at most 128 live caller accounts and
2 MiB of live facet storage are retained per owner. Facets release their scope
charge with actor custody, but releasing them does not replenish issuance work.
These shared execution limits make owner retention explicit. The parent can
create trusted roots; doing so does not create another issuer or backend.

The worker validates backend revisions/pages before settling replies. Its close
report counts completed operations, refusals and failed reply settlements
separately; a successful settlement is not proof the remote application consumed
the result. Failure reasons use the shared 4-KiB UTF-8 prefix boundary. Native
TCP tests cover shared descendant limits, independent callers, malformed backend
answers, queue pressure and cancelled close observations. Local hosted calls
also prove parent and worker retirement refuse further storage work.

Records and attachment metadata preserve JavaScript text through `DocumentText`.
Ordinary text stays UTF-8; isolated UTF-16 surrogates retain their exact code
units in the version-one JSONL codec. Only the outgoing wire projection applies
TextEncoder replacement semantics. Distinct stored identities remain distinct.

`native::archive::file::FileArchive` owns the record journal and an exclusive
`archive.lock` lease. Shared recovery validates snapshot ordering, identities,
revision continuity and record fields before publishing an index. A torn final
line is repaired durably before serving; corruption in a complete line refuses
startup without rewriting the file. Complete input must be valid UTF-8. This
refusal is stricter than the old disk reader's replacement of invalid byte
sequences; escaped UTF-16 surrogates remain valid and lossless.

Writes preserve existing chronology and accept blob digests only from matching
prior attachment metadata. Append and fsync precede index publication and reply.
Compaction uses atomic replacement with file and directory synchronization. A
write whose outcome is uncertain retires the backend until reopen and recovery.
The default bounds are 5,000 records, 512 extra journal rows and 128 MiB. Native
options may lower capacity and file size; the compaction delta is bounded by
5,000. An update that fits only as a compacted snapshot replaces that snapshot
atomically, retaining the prior index until commitment.

Parsing, indexing, serialization and filesystem effects run on a blocking worker.
Immutable record sharing avoids copying retained history across that boundary;
atomic reference counting pays for thread-safe custody. Each snapshot row is
encoded into one owned buffer and written without flattening a second snapshot.
Cancelling an observation leaves the job owned, and a subsequent operation must
observe its result first. A detached job retains the directory lease until it
actually finishes. Session documents use the same native lock/read/replacement
owner while retaining their own codec and filenames.

`proofs/fixtures/archive-disk.json` captures the TypeScript journal loader's
outcomes, including exact UTF-16 units. Native and browser Wasm replay them.
Native filesystem tests cover repair, restart, exclusive custody, limits,
cancelled observations and recovery after an uncertain replacement. A TCP test
holds the disk worker while a sibling actor responds, then checks that a
successful put reply corresponds to a recoverable committed row.

Archive file methods use the same bounded admission as records. `putFiles` validates
live source metadata before retaining capabilities, then streams exact chunks
through a single-slot channel to the disk worker. At most one chunk is queued,
one is being written and one is being fetched; no whole-file buffer is assembled
at the archive. A disk refusal ends an outstanding source observation. Shared `archive::Source` reads bounded chunks from a live file capability or an
existing materialization. The platform supplies the file client deadline.

File ingestion holds no journal or blob-index lock while waiting for a source:
the wait happens before the backend is asked to store anything, so every other
operation keeps its queue order and its original admission charge, and a file
copied from this archive into itself reads committed bytes like any other
caller. An erasure refuses every put whose bytes are still arriving, and a
capture cut short by shutdown is refused rather than left unanswered.
Independent reads use the same current-record validation and disk owner. There
is one such read in flight per hosted worker, with one bounded result chunk.

The blob owner names content by SHA-256, shares repeated content, and applies
reference changes only after the journal commits. Its default retained ceiling
is 512 MiB, with at most one 64-MiB line of temporary staging beyond that budget.
Replacement and eviction may reclaim the retiring record's byte allowance.
Failed removal remains conservatively charged cleanup debt; explicit cleanup,
a later write and startup can retry it. An uncertain journal outcome preserves
staged bytes until recovery. Startup prunes orphans; a retained file is checked
for size and digest on its first read in that process. Missing bytes and corrupt
content refuse reads. Re-uploading matching content can repair a corrupt blob.

`attachment` and `blob` return readers bounded by the issued scope, exact record
address, file position and expected digest. Every read rechecks the current
record; metadata may change around identical bytes, while replacement or removal
of the digest disables the old reader. Each caller session has a separate
512-reader lifetime mint budget, shared across all facets. Reader state uses
immutable shared ownership, so queued reads do not copy its contextual strings.
It shares the archive's live capability-storage budget. Record-only backends
refuse file methods before minting a reader.

Digest selection runs on the serial worker. Its capability reply uses the Host's
owning-thread `Resolver::fulfill_value` in the original caller session. Ordinary
record and byte replies retain the plain-data settlement path. The shared
reader/admission proofs run natively and in Wasm; a native TCP test uploads via
real callback capabilities, reads by attachment and digest, exhausts reader
issuance, and checks scope and stale-reader refusal.

Share identity and revocation live in `application::archive::shares`. The
version-one document preserves issuance order, exact UTF-16 text, the existing
HMAC-derived entropy, 32 active shares and 256 lifetime identities. Retrying the
same share is idempotent; a conflicting or revoked identity refuses reuse.
`FileArchive` stores `shares.json` under its existing directory lease and serial
worker. It publishes a changed ledger only after atomic replacement is durable;
an uncertain outcome disables storage until reopen. Cancellation retains the
pending job just as record writes do. Shared native/Wasm proofs replay captured
TypeScript documents and entropy. Native tests exercise restart, cancellation,
exclusive custody and recovery after uncertain revocation.

`Worker::publish` restores the archive root and its active share publications
through the native Host. Only that root holds durable share issuer authority.
Narrowing drops issuer authority even when a read-write filter still equals the
whole archive. Shared `share`, `revokeShare` and `shares` grammar feeds the same
serial worker as record and blob operations; native clients validate its replies.

Each published share carries a revocation guard through every narrowed facet and
attachment reader. Admission checks it, and queued work checks again before
calling the backend. A read ordered before revocation may complete; a read queued
behind it refuses. Publication removal also prevents future lookup, while held
capabilities lose access through the guard. Caller lifetime budgets remain shared
across durable roots and descendants, independently for each caller session.

Publication follows durable commitment. Failure retains the exact owned names
and specifications for retry; it never rolls back a committed share. A partially
restored set remains unavailable. Startup can retry through
`Worker::retry_publications`; a running issuer retries through its existing share
verbs. A failed storage operation reconciles known committed state when possible;
an uncertain outcome disables shared descendants until storage is reopened.
Healthy listing does not pause held shares during disk I/O. Orderly close revokes
descendants, removes publications and reports cleanup failures separately from
backend completion. Dropping an unrun or interrupted worker also revokes and
attempts publication cleanup.

The TCP proof covers restoration, persisted publication failure and retry,
independent scopes and callers, issuer refusal after narrowing, lifetime mint
limits, descendant/blob revocation and a read queued behind revocation. It also
forces an uncertain share replacement and checks refusal until reopen.

Trusted owners can call `FileArchive::clear` or the hosted `Archive::clear`.
The hosted call joins the same bounded queue as remote writes; archive facets
still expose no erase verb. Cancellation drops only the observation, so the
worker completes the admitted erase before later reads. An empty snapshot
preserves the revision high-water mark and commits before blob references retire.
Durable share identities remain intact. Physical cleanup failures remain charged
and report that records were already erased; retrying clear on an empty account
only retries cleanup. Uncertain journal writes retain old memory and bytes until
reopen determines which snapshot committed.

Native disk tests cover cursor continuity, surviving share identity, retired
readers, cleanup debt/retry and both outcomes of an uncertain replacement. The
hosted TCP test cancels a local erase observation, then proves a later read sees
the committed empty account while remote `clear` remains refused.

`zig build rooms-archive` runs the native Rust service. The shared identity
codec preserves the existing `peer.json` seed and publication entropy; native
storage reads or creates it under the archive lease. Malformed identity refuses
startup without replacement. Session-local stores create no standalone identity
unless their owner explicitly requests one.

The service owns one Host, a listener, the serial backend worker and at most 128
accepted sessions. It restores publications before announcing authority. Shutdown
stops admission, drains the worker, retires publications and closes the Host,
then observes every accepted session. TCP is explicit cleartext; discovery iroh
is the default and direct iroh is available for local operation. Onion startup
uses an already-running Tor and retains `onion-key` through the archive's existing
disk worker and directory lease before readiness. The native gate
exercises TCP/direct-iroh restart with active clients, and the installed executable
under both SIGINT and SIGTERM, including exclusive custody and relative library
loading. Public discovery reachability is not established by these local proofs.

`rooms-archive-build` installs the executable beside its transport companion.
`rooms-peers-test` exercises it without a Deno service process. The
existing archive and browser compatibility tests also launch that executable.
`runtime::session_archive` owns ordered local recording, remote selection,
preparation, shares and erasure. Its 64 admitted requests retain at most 2 MiB of
input and 64 MiB of named file bytes, including requests whose observer was
dropped. Selection takes effect between operations. Live shares retain the source
chosen in that order; durable local shares always read the local backend.
Narrowed shares retain the original revocation state. Their queued reads check
that state before execution and reply, and the serial worker settles the wire
resolver directly. Orderly close removes owned durable lookup names and reports
cleanup failures; retained descendants remain disabled. Hosted and session shares use the same lifetime issuance and
retained-facet budget owner. A failed selected peer stays
unavailable rather than redirecting writes locally. Failed erasure fences later
local access until cleanup succeeds.

The shared merge compares full record identity, then withdrawal/edit state,
current-writer status and listed order. It preserves first-seen row order and
borrows records and identity keys without copying payloads. Input account and row
ceilings include duplicates. Captured TypeScript cases run natively and in Wasm.
The shared owner merges bounded local and selected-peer accounts, cloning only
winning record handles. Caller-held history remains outside the queue budget.

Every merged record carries its actual source. Local sources retain weak access
to their own backend; peer sources keep their original archive across selection
changes. At most 16 selected, prepared or retained peer sources coexist. Unused
sources retire before replacements are charged. Host sturdyref lookup selects an
existing connection or dials; each target retains an independent session owner.
History and blob views borrow that session, so final shutdown can invalidate them
and release its ownership without closing another feature's connection. Explicit
close drains admitted work and reports cleanup and abandoned observations;
interrupted execution invalidates views and cannot report completed shutdown.

Hosted and session archives use the same ingestion queue for writes that stream
bytes to a backend or a peer. While such a write waits on sources, the queue
serves committed-blob reads and retains other commands with their original
admission permits. Queued erasure or revocation refuses later callbacks until
that mutation runs. This permits a local file to be copied back into its own
account, or forwarded to a peer that calls back into the local account, without
making writes concurrent. Backend byte replies remain bounded by the request.
Deferred storage adds at most the existing admitted command count; it neither
replenishes permits nor copies record payloads.

A session recording's capture, the wait for a room or a view to hand over the
bytes it named, does not sit on that queue. Captures run beside it, bounded by
the same stream and byte ceilings, and the worker keeps answering history reads
and storing later lines while a source is slow or has gone. A capture whose
source fails lands its line the way the room keeps it, the file named and its
bytes recorded as unavailable, with the reason on the completion; an erasure or
shutdown that arrives first refuses the line instead.

`KeptRecord::source` converts an archived attachment into a source for the existing
runtime source pool. The source carries its exact local or peer keeper across
selection changes. Erasure and shutdown still revoke its reads. Metadata that
cannot be represented by the live UTF-8 file contract refuses forwarding without
altering the stored document. `Archive::put_sources` streams these sources through
the pool's existing file, byte and active-read limits. It uses the ordinary archive
file protocol and retires its temporary source authority when the call ends,
including after acknowledgement. Ordinary message sends retain their delivered
sources. Each asynchronous read owns
one boxed future through the existing source-reader interface; no whole-file
assembly is introduced. Native proofs forward local and peer files, copy into the
source archive, and verify refusal after erasure and shutdown.

Shared recording policy selects durable messages, preserves line coordinates,
maps edits and refiles to edited rows, and removes text and files on withdrawal.
System messages, typing, disabled retention and messages without line identity
produce no record. Native recording admits the line and its optional room standing
as one operation, so selection or erasure cannot separate those writes. Both use
the caller's admission timestamp. The completion distinguishes a failed line from
a committed line whose standing failed; shutdown reports partial recordings even
when their observers were dropped.

Each archive target remembers successful standing writes in a bounded memo.
It holds at most 128 identities and 256 KiB of retained record payload, separately
from the pending-request budget. Failed writes remain eligible for retry, local
erasure clears the local memo, and another archive receives its own standing.
Eviction permits another write of the same identity. This memo avoids repeated
writes while the archive index remains the authority for stored history.

`proofs/fixtures/archive-recording.json` captures the historical TypeScript
`DurableRoomsArchive.recordMessage` output with a fixed clock. Native and Wasm
replay message selection, coordinates, changes, file metadata and distinct room
scopes. Additional proofs exercise memo limits and commitment. Native tests cover
partial writes, retries, erasure ordering, abandoned receipts and archive changes.
The file scenario records attachments into local and remote accounts. Native
recording starts source capture at admission on the session LocalSet, independently
of queued storage. Each file is read sequentially into immutable bounded chunks;
files can progress concurrently, preserving their original attachment order.
Completed captures survive source retirement while an earlier write is blocked.
Capture failure refuses the recording and cancels sibling captures. A dropped
receipt does not cancel admitted work or refund its retained-byte charge.

Recording preserves message metadata when the 64-MiB pending file budget or the
32-active-capture limit is reached, or the selected local backend does not retain
bytes. These cases start no capture tasks. Completions distinguish the causes,
and shutdown counts metadata-only recordings. Capture descriptors and chunk
ownership metadata also consume the 2-MiB input budget; task count is bounded
separately. Ordinary requests keep inline admission custody; capture tasks and
buffers share custody until they retire.

Local disk writes share captured chunk allocations. Remote replies copy only the
requested span; crossing a chunk boundary assembles at most one reply chunk.
The separately bounded disk channel and active disk write can retain two shared
chunks after capture custody ends. The 64-MiB budget is therefore a file-custody
bound, not a claim about total heap use or transient protocol buffers. Native
tests cover blocked local and remote writes, retired sources, abandoned receipts,
both capture limits, source refusal, worker interruption and temporary authority
retirement after acknowledgement.

Native proofs cover blocked writes, abandoned replies, failed selection and
erasure, shared-connection reuse, file copies into their source archive, scoped
shares, retained views, and shutdown with another client still using the Host.

`DirectEvents::with_recorder` connects shared incoming and outgoing messages and line
changes to recording before publishing each event. It samples committed retention
at event publication; outgoing messages retain the nickname captured before delivery,
while incoming messages use the current committed nickname. Event-consumer delay
cannot postpone capture or change that decision. Typing creates no archive work. A recording refusal remains on the
event alongside the accepted message, and a successful admission carries its
coordinates and separate persistence receipt. Event custody charges those
coordinates or a bounded diagnostic in addition to message content.

An edit notification contains no attachment suffix: it preserves the line's
existing files. The recorder takes that metadata from the authoritative line
before dispatch instead of interpreting the notification as a complete snapshot.
Refiling supplies the new file set; withdrawal records no files. The incoming media
owner captures bytes, and recording pins that materialization for archive storage.
Archive closure cannot prevent the direct producer from delivering subsequent
messages with recording refusals.

Incoming files use their actual delivering context. `File::received` resolves and
retains the capability's exporter on the first asynchronous read, outside the
actor turn. Local capabilities use the supplied client; an unrelated directory
connection is never substituted. The ordinary client deadline and transfer checks
still apply. Native capability tests record across two directories before consumer
delivery, exercise edits and policy changes, and read a sibling export after the
contextual connection closes. Dropping that file does not close another owner's
exporter connection.

Immutable materialization lives in the shared Rooms file client.
`rooms_runtime::media_files::MediaFiles` owns capture tasks for capabilities and
local sources. Independent readers share each retained materialization. Native
tests use the real sender source pool: one complete source read supplies two
readers and a local archive write, including renamed metadata over the same
bytes. Chromium exercises the same capture owner against a native room while
bytes are arriving: two lines share one materialization, final selection
retirement refuses new readers, and admitted readers finish.

The receiver bounds custody to 128 files, 64 MiB and 32 active captures. Zero-byte
files spend count capacity. Pending capture and pinned readers cannot be evicted
to admit new work; pressure can expire completed unpinned views. Materialization
admission pins the result before its future is polled, so later view expiration
does not cancel an archive's accepted observation. Completed leases keep their
byte charge through owner closure. Cancelling a close observation leaves its
task handles owned and available to a later close. Capture refusals are bounded.

Room message pumps now pass their admitted media views to the same recording
boundary as direct messages. If the media pool refuses admission, the archive
receives the original attachment capabilities and applies its own capture budget.
That preserves recording under preview pressure without rereading an admitted
capture. Sparse room edits recover their unchanged attachment descriptions from
bounded session history. If those facts have expired, the archive admission
reports the missing history instead of replacing the file set with an empty one. Recording receipts stay in the bounded membership pump; retirement
releases their observation while the archive finishes admitted storage work.

`SessionArchive::record_files` pins those materializations at recording
admission and shares their chunks with local or remote ingestion. It neither
reads the sender again nor assembles another file buffer. Explicit live-source
recording retains its original capture path; both paths share ordering, receipts,
metadata fallback and custody accounting. Returned reader buffers remain
caller-owned; the separately bounded disk spans can outlive a materialization.

Shared `DirectEvents` uses this receiver. The shared line policy presents a
validated full attachment selection before mutation. Event and media capacity are
reserved there; malformed changes and refused batches leave the line unchanged.
The receiver preflights the whole batch, deduplicates capabilities and excludes
selected files from eviction before any source starts. Wire edits remain deltas;
`Event::files` supplies the full received-file view, and recording uses
`record_files`. Neither caption edits nor preserved refile attachments reread
the sender, including when recording was disabled at the original post.

The incoming media owner retains at most 2,000 line selections, evicting the oldest
line identity for scrollback pressure. Its byte cache has the independent limits
above. A line actor keeps only weak media history, so a later change can report an
expired attachment without rereading an exhausted source or retaining a Host
cycle. Removing a selection expires its bytes only when no sibling line selects
that materialization; already admitted readers and recordings retain their leases.
`DirectEvents::close` stops event admission. `close_files` also expires views and
observes capture cancellation, retaining ownership across cancelled observations.
A parent preserving queued recordings drains its archive before closing media.

Native capability tests use one-pass sources for views, recording, edits and
refiles; they cover shared selections and final withdrawal. Native/Wasm proofs
exercise validation before admission and refusal without staged-file mutation.
Batch tests cover conflicting sizes, selected-file protection, duplicate sources,
active pressure and weak history after its last strong entry is gone.

`native::session_retention::RetentionEvents` composes local history erasure with
any native session event owner. `session_retention::directories` provides that
composition for directory realization. Start the archive worker first, await the
constructor, then publish the session and run its command/directory workers.
A restored history-disabled checkpoint erases local remnants before readiness.

The session worker settles critical effects after each published durable boundary
and before starting another transaction or reconciliation write. A retention
command's checkpoint may have committed when its reply reports an erase failure;
the reply is not a rollback. A later attempt retries that outstanding barrier
before it may mutate state. Re-enabling history therefore cannot reach disk until
the preceding erase has completed. Dropping a command reply does not abandon its
work. Shutdown also settles the barrier before claiming success.

Archive pressure delays erasure admission within the existing bounded queue.
A fair semaphore owns the 64-request count budget, including capture custody.
A waiting erase receives released capacity before newer requests can consume it;
worker or archive closure refuses explicitly.
The erase uses the existing local FIFO command and ingestion fences, including
retry after physical cleanup failure. It neither clears the selected remote peer
nor changes archive selection. Close command/directory producers before closing
the archive they need to settle.

The disabled checkpoint itself is the recoverable intent. If the process stops
before erasure, restart clears it before readiness; if a later enabled checkpoint
exists, the preceding barrier already completed. No additional journal or document
version is needed. This guarantee requires all production session mutations to run
through the command owner and retention adapter. Low-level DurableSession methods
remain persistence primitives. Native tests cover a full archive queue, blocked
and failed erasure, abandoned replies, interrupted workers and actual file reopen;
shared native/Wasm proofs exercise the retention transition policy.

The session peer runs Rust in deployment and process scenarios. The former Deno
session entrypoint has been removed; `zig build rooms-session` and Compose start
the same native implementation.

The native `DirectOutgoing` owner sends messages and retains their returned
edit capabilities, scoped to the exact accepted conversation. Its worker owns
admitted effects even when callers abandon replies. One pending effect per
conversation prevents competing file selections; up to 32 conversations progress
independently. Requests and completed observations share a count and byte budget.
A separate 2,000-line registry bounds delegated authority; media retains the
independent limits above. The parent establishes routes and owns the wire source
pool, then closes this worker before its event, source and transport owners.

Outgoing event capacity is reserved before contacting the peer. Local file
capture must complete first. The shared `Line` state machine validates edit,
refile and withdrawal selections before source admission; it remains the only
mutation grammar. Accepted messages publish full file views and recording
receipts with explicit direction, sender and editability. Line identifiers come
from the same event owner as incoming messages, qualified by its generation.

A byte-backed `Source` shares its original allocation with local materialization;
a reader-backed source is captured in bounded spans. Peer one-pass grants read
that materialization, so consuming a grant does not consume the sender's local
view or recording. Kept attachments survive refiling; removed selections expire
views while admitted readers keep their leases. Expired previews do not block
caption edits or kept attachment indices; an unavailable capture remains an
explicit recording failure alongside the accepted change. Disk handoffs retain at most a
64 KiB allocation: an already bounded capture shares storage, while a span into
a larger contiguous local file copies just that span before crossing executors.

Delivery failures distinguish not sent, uncertain outcome and peer accepted.
Acknowledgement after conversation retirement reports accepted without publishing
into the retired conversation. An uncertain mutation retains its actual capability
for idempotent withdrawal but refuses edits and index-based changes. There is no
automatic resend. TCP tests cover cross-conversation isolation, abandoned replies,
queue pressure, retained receipt budgets, source failure, mutation uncertainty,
retirement, recording and shutdown. The session peer ledgers outgoing direct
commands through its command owner and composes this owner with its views.
