# Shared Rooms execution

This crate orders the platform effects needed to execute Rooms policy. The
native session binary uses it for initialization, checkpoint/effect commits,
recovery, bounded command admission, ordered live-fact retries, directory
supervision, room membership, media custody, direct messages, archives and grant
publication and session capability dispatch. The same owners compile for browser Wasm.

`DurableSession` takes exclusive `Documents` custody and an `Entropy` adapter.
`SessionCommands::open` additionally takes a monotonic `Clock` and returns the
command handle and its worker. Run the worker on the application's LocalSet.
Dropping a reply abandons observation; admitted work remains owned. `stop`
ends admission synchronously, while `close` also observes worker retirement.

Storage adapters retain pending work across observer cancellation. Recovery
must observe those completions before reloading, and an uncertain write must
remain uncertain. Storage errors retain their concrete platform type. Borrowed
`SessionView` access has its own errors and never depends on a storage backend.
The adapters use static dispatch; this boundary adds no boxed I/O futures.

`VolatileDocuments` holds checkpoint/effects bytes only for its lifetime. It
supports tab-hosted sessions with the same lifetime as their browser Host;
workspace preferences and archive records have separate persistence owners.
Writes transfer their bounded buffer directly into the document slot. Reads
copy each stored document once so restoration cannot consume the committed
source. Native files instead retain their directory lease in pending workers.

`DurableGrants` takes one fixed-role `Document`. The adapter owns bounded reads,
atomic replacement and pending operation custody. `PublishedGrants` restores and
reconciles durable names; held facets consult the committed ledger on every call.
`GrantCommands` orders writes, publication and attached-view notifications before
replying. Its handle and notification effects do not depend on the storage type.
Native documents and tab-lifetime `VolatileDocument` use the same execution;
uncertain writes require observed completion and restoration on either backend.

`connections` owns bounded acquisition per transport and peer identity. Clients
share a weak cache and the same directory watch/name registry. Cancelled
readiness leaves the dial owned until it finishes; an unobserved connection
retires before a replacement starts. The binding closes a transport when its
final owning client leaves.

`session_directory` owns connection attempts, discovery watches, registered
names and reconnect vouchers. Its shared connection pool uses the binding's
`Runtime` with native providers or browser connectors and a client scheduler. Dropped
readiness observations retain the attempt; explicit close waits for retirement.
Adoption transfers held authority without redialing. Intent is rechecked after
durable reconciliation and registration, before exposing a live directory.

`directory_runtime` supervises bounded connection attempts and reconnects with
the supplied monotonic clock. Its event adapter retires obsolete generations
synchronously with a committed checkpoint, before command acknowledgement.
Direct acceptance, received room links, and handed room capabilities share
that generation owner. Restoring identical intent cannot revive retired work.
An exclusive entropy adapter supplies identifiers without cloning generator
state. Hosted receivers hold weak runtime custody; retiring one owner releases
its references and watches without closing a shared transport session.

The `takeRoomLink` result command resolves a pasted capability on its directory
connection. Live reference identity selects an existing membership; a new
membership is subscribed before its conversation row is committed. The room
worker takes that prepared membership and its buffered messages. A foreign
directory connection remains provisional until the same commit admits it.
Failed admission retires the prepared membership and relinquishes the lookup's
client without closing a sibling owner. The result ledger retains the chosen
membership or returned name for recovery.

`direct_routes`, `route_openings`, `direct_publications` and `direct_dispatch`
own reciprocal routes, coalesced openings, bounded inbox publication and notice
execution. They use the accepted context on every delivery and after awaited
effects. The parent supplies the message receiver and owns message/history
storage; hosted reply actors retain weak route custody. Reciprocal timeouts use
the platform clock, and shutdown observes owned opening tasks before releasing
publication state.

`media_files` owns shared file capture and reader pins; `media` leases each
line's selection from one pool. A selected file has one materialization even
when views, edits and recordings read it together. Final selection retirement
refuses new readers while admitted readers keep their bytes and budget charge.
`command_files` freezes and hashes the same immutable storage used for delivery.

`direct_events`, `direct_outgoing` and `direct_commands` share message admission,
delegated edits, typing, file delivery and durable command completion. The
platform supplies wall time for timestamps separately from monotonic deadlines.
`archive_recording::Recorder` admits recording synchronously and returns shared
receipt types; `session_archive` owns capture, selection and erasure over a storage backend.
Dropping an event or receipt abandons observation without cancelling admitted
archive work.

`rooms` realizes all intended memberships, joins by link/publication/name,
installs newly acquired manager authority before exposing a membership, commits
learned authority and policy, and owns message pumps, line capabilities and
exclusive staged uploads. Attachment facts are bounded across all rooms; sparse
edits preserve files even after preview admission refused an earlier selection.
Authority rotation preserves the membership and its callbacks. Missing saved
publications become generation-checked checkpoint retirements, including after
restart. It retains one entropy source for recovery keys;
cloning a runtime handle never clones a generator. Room and direct timestamps
use the same explicit wall-clock boundary.

Room recording reuses admitted media captures. If media admission refuses, it
passes the original received capabilities to the archive's independent admission
budget. Each membership pump bounds and polls its recording receipts directly;
retirement drops observations without cancelling archive work. Room callbacks
hold weak runtime custody. Membership retirement wakes pumps waiting on full
view-event queues, pending line receipts or message streams.

Hosted session facets use a weak handoff receiver to accept or dismiss live room
offers. Acceptance stays in the handoff worker through durable completion, even
when its caller abandons the reply; an exact retry returns the recorded revision.

`archive` hosts bounded record and file methods. `session_archive` orders local
recording, peer selection and erasure, while file capture progresses independently.
Both use `Backend` for committed storage and `Source` for bounded file reads.
The native adapter retains the journal, blob directory and blocking disk jobs.
Shares retain their source across selection changes and their revocation through
narrowing. Shared facet budgets bound bytes and lifetime issuance; share replies
stay in the serial worker through wire settlement.

`operations` and `peering` realize checkpoint credentials and publication leases
with platform deadlines. Their retained capabilities must belong to the exact
current directory connection. Peering rechecks source membership, destination
connection and committed intent after awaiting publication. `room_offers` owns
durable receipt acknowledgement; `archive_shares` retains received capabilities
and one exclusive entropy source, refusing retired direct contexts.
`session_projection` constructs the shared bounded snapshot from these owners;
the native service adapts its errors and the browser can project the same data.

The native session specializes these owners with its scheduler and OS entropy.
Its archive-retention barrier also lives in the shared runtime. The Chromium
proof exercises directory adoption, discovery, committed removal and shutdown
through the shared supervisor. It also exercises shared media capture from a
native room through late bytes, concurrent readers and selection retirement.
The room runtime scenario drives two memberships, uploads, sparse edits,
withdrawal and closure with a full event queue against the native directory.
Dropping manager authority retains the exact membership and its editable line.
Native direct scenarios exercise the shared route, message and command owners;
the production browser uses the same application owners. The IndexedDB archive
adapter has Chromium compatibility proofs and production page ownership.

`session_service::Facet` dispatches the session protocol and owns attached views.
Native `rooms-session` and the Wasm proof both construct it through
`session_service::Session`. That owner starts, supervises and closes all session
workers, including retention, grants and the root publication. Deferred replies, file reads and attachment acknowledgements have a
256-task ceiling and retire when the facet closes. Reply admission precedes
checkpoint submission; a full reply owner cannot commit that mutation. View
snapshots still precede durable replies and follow current grant rights.

Closing the session disables held views, removes its root and drains dependency
owners before joining workers. Session commands finish their retention barrier
before the archive closes. Partial startup follows the same cleanup path and
retains primary and cleanup failures. The runtime belongs to the embedding and
remains usable after application close.

Native process startup owns checkpoint file reading, listener readiness and
operator reporting. Shared errors keep policy, admission, state access and CapTP
causes distinct; the native adapter retains those causes beside its storage and
listener failures. Visualization is an explicit composition interface: native
publishing is supplied by `rooms-session`, while the Wasm facet proof uses a
fixture. Browser visualization and production page composition remain migration
work. Closing a facet stops visualization admission; native socket retirement is
still owned by its bounded publisher loop.
