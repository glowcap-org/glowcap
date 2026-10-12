# Rooms session ownership and recovery

Living-state surface. Rooms uses one managed session implementation for the
process peer and browser workspace. Loam owns durable content, exact capability
fields, access grants and effect receipts. Rust owns application intent and
execution. React presents observations and submits reader intent.

The [shipped inventory](../../apps/rooms/shipped.md) describes product behavior.
The [recursive resource plan](../planning/rooms.md) covers room,
directory and archive authority work beyond the session.

## Owners and consumers

Paths in this table are relative to `apps/rooms/`.

| Surface | Owner | Contract |
| --- | --- | --- |
| Declarations | `rust/application/src/content/session/` | Workspace, custody and effect codecs. Permission requirements, presets and generated browser metadata. |
| Runtime | `rust/runtime/src/session/managed/` | Source admission, atomic custody and receipts, supervised workers and bounded readers. |
| Process | `rust/services/src/session/`, `rust/product/src/bin/rooms-session/` | LMDB bootstrap, stable independent use/control publications and typed local-control operations. |
| Browser | `rust/browser/src/attached/managed/`, `rust/browser/src/storage/` | Per-tab IndexedDB bootstrap, exact saved fields and retained Wasm handles. |
| Clients | `rust/glowcap/src/client/workspace/`, `rust/glowcap/src/client/access/` | Local and remote workspace calls, retained requests and independent management. |
| Page | `web/ui/session/managed/`, `web/ui/main.tsx` | Intent/activity projection, drafts, navigation, history, files and explicit recovery. |
| Access editor | `web/ui/settings/` | Separately held controls, permission groups, revision-checked changes and descriptive inventory. |

The [effect contract](session-effects.md) owns admission, dispatch and settlement.
The shared Host carries local and remote calls through the same typed clients.
Local opening needs no relay connection. Publication prepares reachability on
demand. A foreign control keeps its established owner route.

## Shutdown

JavaScript mutation handles last only while their application owner lives.
Committed receipts survive independently in shared storage. Callback shutdown
retains admission until its exact upstream seat or name retires. Unknown
admission refuses cleanup. A failed browser close retains the owner for retry.
Disposal relinquishes that recovery handle. Managed inboxes must close before
their session attachment and Store.

## Storage and startup

`managed::Opened` owns the callback, receipt workers, attachment and Store in
dependency order. `managed::Bootstrap` persists identity, provisional metadata,
the resource commit and its independent live marker before exposing public
use/control. Reopening recovers the original branch derivation. Initialization
validates workspace and receipt metadata without restoring every custody field.

The process uses LMDB, atomic filesystem metadata replacement and a directory
lease. The browser uses per-tab IndexedDB metadata and the Store's exclusive
Web Lock. Metadata replacement compares the previous bootstrap transactionally,
so delayed preparation cannot overwrite a confirmed root. Both browser metadata
and Loam require strict durability. Confirmed root absence and uncertain storage
refuse startup.

Workspace intent, custody and receipts commit as one registered codec graph.
Shared sizing derives physical record and graph budgets. Strong fields retain
the exact grant and target generation. Typed coordinates identify those fields.
A nickname, row ID or serialized view supplies no authority. Acquiring a bearer
link is an explicit operation that saves the resulting capability.

Browser readers share the newest accepted workspace revision. A delayed older
reply cannot roll back presentation or the snapshot used to prepare a command.
Editable candidates copy that accepted snapshot before changing it.

Fresh Host startup retires old registrations, direct routes, callbacks,
publication leases and line edit selections before public access or supervision.
Nickname choices, drafts, history identity, introduction witnesses and original
receipts remain. The live marker fences observations from an earlier execution.

## Completion and recovery

Status, receipt observation and adoption checks require the original operation's
permissions and its exact source witness. Collaborators can finish their own
drafts and actions. Inventory, recovering canonical intent, resuming an executor
and releasing a receipt require `ResolvePending`.

A terminal receipt can still have a retained executor when settlement commits
before its worker observes the reply. Recovery continues that exact executor
through settlement and cleanup. It does not dispatch the upstream action again.
A cold unknown receipt has no executor to resume and remains unknown.

Posted-line and direct-introduction acquisition admits the exact result change
with the original participation permissions. It preserves unrelated workspace
intent and checks returned identity, target custody, releases and initiating
source. A stale candidate with changes reports conflict before installing
custody or intent. General result acquisition still requires custody management
and workspace replacement.

Activity delivers message text and attachment metadata independently of byte
access. A refused file reader stays with that attachment and retries its exact
activity selection when opened again. It does not stop message observation or
grant permission to read bytes. An expired selection refuses retry instead of
selecting another file.

## Membership and direct-message lifetimes

Directory, room and direct rows retain their exact initiating session endpoint.
Worker startup restores that endpoint and the row's selected targets.
Installation, registration/subscription and returned-facet acquisition commit
the actual callback identity with its intent. Replacing an inbox, source,
entrance or registration fences that callback and retires its worker.

`Memberships::reconcile` preserves sibling workers and shared field aliases.
One `WorkspaceActivity` observation drives the aggregate. Private content and
grant observations wake workers to check their held sources. The wake carries
no content or authority. Terminal executor progress wakes receipt readers even
when no content transaction occurs. Standing reconciliation reuses the wake's
snapshot. Startup permits bound candidates independently of live inbox capacity.

Removing a row requests retirement. The session keeps the task through reply
drain and upstream leave. Failed cleanup retains exact custody for retry.
Interrupted waits keep their original receiver, and unknown subscriptions stay
unresolved. Cleanup cannot remove a successor registration or membership.

Direct workers publish their actual reciprocal inbox. Introductions check local
and peer registrations and retain the original witness in their receipt.
Reconnect replaces saved live custody and fences late adoption against newer
navigation. Incoming notifications cannot reopen a closed conversation.
Removing a closed sidebar entry submits workspace departure.

The viewer registers its readiness wait before requesting an introduction, so
an early notice remains available. Only the original directory, registration
and opening can satisfy it. A pending introduction starts a 30-second local
deadline. Closing the viewer, cancelling the wait or reaching that deadline
refuses the wait without dispatching another introduction. Ending this local
wait does not cancel an admitted effect or discard its receipt.

The composer transfers submitted text and files from the editable draft into an
immutable plan. Later typing and queued submissions retain independent owners.
Result acquisition cannot clear a later draft. Recovery names the original
operation. Equal message text cannot select it.

## Discovery, signaling, archives and bridge secrets

Managed directory readers retain the viewer's own access grant and upstream
target. ObserveWorkspace permits named reads through independently shared access.
Pausing or revoking that grant also stops its retained readers. Background
discovery workers keep the directory's initiating source. Named public resolution
can find a durable room with no members. Publication witnesses
describe current generations and disclose no bearer entropy. Private rooms
have no named public witness. Public listing pagination remains a separate
[known limitation](../roadmap.md#further-application-work).

Signaling retains the exact directory, registered name and initiating source.
Its facade rechecks that selection, while upstream admission refuses expired or
replaced names. Browser listeners retain their own cancellation and retirement
custody. The saved connection choice selects relay or WebRTC advertisement.

History reads the selected archive, or the owner-scoped recorder when none is
selected. Archive reads have independent permissions and mediated file readers.
Disabling recording commits a pending erasure identity. The archive worker
erases that recorder source's records and bytes before settling its receipt.
Enabling history or replacing configuration cannot bypass that barrier.
Other owners and shared blob references survive scoped deletion and restart.

Bridge dispatch retains its exact origin and witness-based secret recovery.
Form readers disclose only the declaration and recheck the original session
source. Secret acquisition and command execution keep separate owners.

## Management

Use and management are separate capabilities. Independently held controls expose
Inspect, Issue, Edit, DelegateControl and lifecycle powers. Configured permission
dependencies and kind applicability are enforced by shared Loam declarations.
Labels, inventories and IDs describe access. They cannot recreate a control.

Fresh edits and issuance check the expected revision. Issuance advances its
source's revision, so a committed issuance rereads the source before the next.
Exact replay recovers the original receipt before treating an old revision as
a new request. Issuance
keeps every management power the source can pass on. Its editable ceiling is
bounded by both the source's edit and issuance ceilings. Sharing management
creates a separately attenuated control with the selected powers.

Revocation ends access for good. Its grant record stays as a tombstone, so an
old link or ID can never reach access issued later, and the issuer's inventory
lists it as revoked. Revoking from the editor also removes its row. Removing a
row is a separate act that releases the saved row and leaves the access
untouched. A live row asks first, because removal gives up the only way to
manage it from this workspace. The workspace's own control is never removed.

The editor retains uncertain requests and preserves drafts on conflict. A
completed issuance clears its pending flow. Distinct action keys prevent a
completed button from becoming a form submitter during the same click. A
control without Inspect can display only the label and permissions this
viewer knows it committed. Powers fixed at issuance cannot be added later.

## Evidence and costs

The graph and effect proofs close and reopen real storage on Linux/LMDB and
Chromium/IndexedDB, and check receipt replay, unknown commit outcomes, source
loss and capacity refusal. The foreign-field trace restores 3,592 fields in 64
pages.

`rooms-web-proofs` drives the production page through share, issue, edit,
pause, resume, revoke, removal, conflicts, reconnect and reload, and restarts
the process peer. The release image proof recreates the session container over
its saved volume and checks that the iroh locator and both publications
survive. [Session measurements](../../bench/rooms/session-costs.md) record
locator, accept and UI projection costs. End-to-end DM latency is not measured.
