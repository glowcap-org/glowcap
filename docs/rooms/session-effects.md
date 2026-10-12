# Rooms session admission and effect execution

Living-state surface. The [session guide](session.md) maps production owners
and startup. This page describes how managed commands preserve source admission,
target custody and recoverable outcomes across external effects.

## Admission and receipts

`content::session::requirements` declares application admission. `EffectReceipt`
records the original source, resource incarnation, exact target fields and
canonical intent before dispatch. Typed custody resolves each selected target
once. Local and wire calls use the same executor. Local ownership retains
explicit root use and control capabilities.

The shared hosting boundary retains an owned continuation, its bounded reply
allowance and completion/cancellation custody. Confirmed receipt commit
activates dispatch. Abort discards the reservation. Unknown commit retains it
behind recovery. A borrowed callback invocation cannot outlive its turn.

Dispatch, recovery and protected delivery recheck the original source and
target authority. Replacement of a conversation or custody slot cannot redirect
pending work. Returned capabilities stay exact retained results. Replay cannot
mint replacements. Malformed acknowledgments preserve uncertainty even when
the upstream operation applied.

Recovery requires the caller's held pending-effect or result authority together
with ResolvePending. An operation ID cannot select another grant's receipt.
Concurrent resumes share one dispatch owner. Changed intent refuses, and replay
pressure cannot evict an unresolved receipt. A missing receipt confirms absence.
It does not authorize preparing or resending the original effect.

## Cancellation, source loss and shutdown

Canceling a caller's wait releases its observer. Committed work retains its
targets and private execution through settlement. Source pause or revocation
prevents further dispatch and protected disclosure, while exact completed
custody remains available to internal settlement.

The executor distinguishes failure before target admission (`unsent`) from
failure afterward (`unknown`). The application receipt owns the judgment about
durable application. Temporary result allocation refusal keeps the completed
reply for retry without redispatch. Permanent reply-size or identity refusal
settles as unknown instead of retrying forever.

Shutdown drains physical workers before releasing their buffers. Failed close
retains the full composition for another attempt, including its original serving
tasks. The Host remains alive while private settlement needs it. Durable receipts
remain until explicit terminal retirement.

## Atomic acquisition

Workspace acquisition retains source, imported capabilities, expected revision
and complete candidate intent across cancellation and retry. ManageCustody and
ReplaceWorkspace are required. Stale revisions return explicit conflict before
saving capabilities or changing content. Unknown replies keep the original
candidate. Only confirmed conflict permits bounded re-preparation through the
same source.

Result acquisition atomically adopts seat, topic, file and initiating endpoint
fields with intent. Invalid selection imports nothing. Exact replay changes no
revision, and intervening edits refuse the retained candidate. Receipt targets
retain independent occurrences when workspace custody is released.

Occupied custody accepts only the same actual capability, with its checked role
and generation. Releasing local fields requires no working upstream grant and
restores no predecessor authority. Created-room adoption appends through the
receipt's exact directory target while preserving unrelated current fields.
Removing or replacing that directory refuses adoption.

## Exact upstream operations

Application dispatch declarations own argument validation and role selection.
Entry, RoomAccess and RoomControl remain separate actual targets. Moderation,
policy edits and unregistration use the selected management capability.
Missing moderation authority cannot fall back to entry. `ensureRoomLink`
uses RoomControl and saves its returned RoomAccess separately from descriptive
coordinates.

Discovery and introductions retain selected directory/name fields. Direct
transitions retain the actual inbox, source, scalar arguments and registration
witness. Interrupted observation and settlement keep those same targets.
Canonical upstream conversation identity and generation govern history and
line identity. Session permissions add admission. They cannot replace upstream
membership or authorship checks.

## Files and mediated readers

Room uploads retain original RoomFiles, optional Line and source blobs before
dispatch. Confirmed staging precedes post/refile. The acknowledged primary
effect precedes bounded filling. If filling fails, the applied line remains
with an explicit incomplete-file outcome. The worker retains its complete fill
future through interruption, including an append awaiting acknowledgment.
Sender leases pin sources through settlement. Expiry and in-flight reads own
independent lifetimes.

Direct delivery lends shared read scopes over the admitted sources, then sends
one direct post/refile. Those scopes keep immutable continuation custody after
worker retirement. They allow only the declared read methods and capability
results. Delivery stages no file bytes and performs no source reads.

History, archive and file facades retain exact upstream targets and the original
session source. Every chunk and protected result rechecks both admissions.
Independent archive selection needs ReadArchive. Files also need ReadFile.
Explicit reader release prevents disclosure from an in-flight read.
Forwarding budgets derive complete page and blob reply demand from application
bounds and shared sizing, with bounded temporary result storage.

## Observation

Snapshot, watch and local observation use the same source admission. The runtime
materializes one snapshot per tick and projects it for each checked source.
Observation registrations retain exact receiver, authenticated cursor and
cancellation custody. Policy narrowing and source loss invalidate cached lines,
previews, roster and unread summaries. Queued delivery after loss reveals status
only. Independent cancellation cannot retire another receiver.

## Evidence

The shared Zig owning-delivery proofs check exact arguments and replies, failed
turn rollback, Host retirement, forwarding, deferred refusal and cancellation.
C/Rust continuation limits project count, bytes, target occurrences and reply
capacity from that owner. Reservations borrow the turn. Confirmation transfers
custody once to the executor.

The [runtime executor scenarios](../../apps/rooms/rust/proofs/src/session_executor.rs)
run the same contracts on Linux and Chromium. They cover pause/revoke during
waits, replacement before polling, wrong recovery grants, duplicate resumes,
lost replies, constructor/refill refusal and cold unresolved replay without
another upstream act. LMDB and IndexedDB proofs physically reopen storage and
retain the foreign exporter. Production page journeys additionally establish
consumer adoption, shared-session recovery, files and management behavior.
