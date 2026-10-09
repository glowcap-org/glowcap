# Rooms session ownership and recovery

Living-state surface. Rooms uses one managed session implementation for the
process peer and browser workspace. Loam owns durable content, exact capability
fields, access grants and effect receipts. Rust owns application intent and
execution; React presents observations and submits reader intent.

The [shipped inventory](../../apps/rooms/shipped.md) describes product behavior.
This page explains session ownership and recovery. The
[recursive resource plan](../planning/rooms/integration.md) covers room,
directory and archive authority work beyond the session.

## Owners and consumers

Paths in this table are relative to `apps/rooms/`.

| Surface | Owner | Contract |
| --- | --- | --- |
| Declarations | `rust/application/src/content/session/` | Workspace, custody and effect codecs; permission requirements, presets and generated browser metadata. |
| Runtime | `rust/runtime/src/session/managed/` | Source admission, atomic custody and receipts, supervised workers and bounded readers. |
| Process | `rust/services/src/session/`, `rust/product/src/bin/rooms-session/` | LMDB bootstrap, stable independent use/control publications and typed local-control operations. |
| Browser | `rust/browser/src/attached/managed/`, `rust/browser/src/storage/` | Per-tab IndexedDB bootstrap, exact saved fields and retained Wasm handles. |
| Clients | `rust/glowcap/src/client/workspace/`, `rust/glowcap/src/client/access/` | Local and remote workspace calls, retained requests and independent management. |
| Page | `web/ui/session/managed/`, `web/ui/main.tsx` | Intent/activity projection, drafts, navigation, history, files and explicit recovery. |
| Access editor | `web/ui/settings/` | Separately held controls, permission groups, revision-checked changes and descriptive inventory. |

The [effect contract](session-effects.md) owns admission, dispatch and settlement.
The shared Host carries local and remote calls through the same typed clients.
Local opening needs no relay connection; publication prepares reachability on
demand. A foreign control keeps its established owner route.

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
the exact grant and target generation. Typed coordinates identify those fields;
a nickname, row ID or serialized view supplies no authority. Acquiring a bearer
link is an explicit operation that saves the resulting capability.

Fresh Host startup retires old registrations, direct routes, callbacks,
publication leases and line edit selections before public access or supervision.
Nickname choices, drafts, history identity, introduction witnesses and original
receipts remain. The live marker fences observations from an earlier execution.

## Membership and direct-message lifetimes

Directory, room and direct rows retain their exact initiating session endpoint.
Worker startup restores that endpoint and the row's selected targets.
Installation, registration/subscription and returned-facet acquisition commit
the actual callback identity with its intent. Replacing an inbox, source,
entrance or registration fences that callback and retires its worker.

`Memberships::reconcile` preserves sibling workers and shared field aliases.
One `WorkspaceActivity` observation drives the aggregate. Private content and
grant observations wake workers to check their held sources; the wake carries
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
Removing a closed rail entry submits workspace departure.

The viewer registers its readiness wait before requesting an introduction, so
an early notice remains available. Only the original directory, registration
and opening can satisfy it. A pending introduction starts a 30-second local
deadline. Closing the viewer, cancelling the wait or reaching that deadline
refuses the wait without dispatching another introduction. Ending this local
wait does not cancel an admitted effect or discard its receipt.

The composer transfers submitted text and files from the editable draft into an
immutable plan. Later typing and queued submissions retain independent owners.
Result acquisition cannot clear a later draft. Recovery names the original
operation; equal message text cannot select it.

## Discovery, signaling, archives and bridge secrets

Managed directory readers retain the exact source and upstream target. Named
public resolution can find a durable room with no members. Publication witnesses
describe current generations and disclose no bearer entropy; private rooms
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
Labels, inventories and IDs describe access; they cannot recreate a control.

Fresh edits and issuance check the expected revision. Issuance advances its
source's revision, so a committed issuance rereads the source before the next. Exact replay recovers the
original receipt before treating an old revision as a new request. Issuance
keeps every management power the source can pass on; its editable ceiling is
bounded by both the source's edit and issuance ceilings. Sharing management
creates a separately attenuated control with the selected powers.

Revocation ends access for good. Its grant record stays as a tombstone, so an
old link or ID can never reach access issued later, and the issuer's inventory
keeps listing it with its label as revoked. A revoked control describes itself
as unavailable and has nothing left to manage, so revoking from the editor also
removes its row. Removal is its own act: one workspace acquisition releases the
saved row and leaves the access untouched. A row revoked elsewhere offers it at
once. A live one asks first, because that removal gives up the only way to
pause, change or revoke it from this workspace. The workspace's own control is
never removed.

The editor retains uncertain requests and preserves drafts on conflict. A
completed issuance clears its pending flow. Distinct action keys prevent a
completed button from becoming a form submitter during the same click.
A control without Inspect can display only the label and permissions this
viewer knows it committed. Powers fixed at issuance cannot be added later.

## Evidence and costs

The graph and effect proofs run on Linux/LMDB and Chromium/IndexedDB. They close
and reopen real storage, retain a surviving foreign exporter and check exact
receipt replay, unknown commit/abort outcomes, source loss and capacity refusal.
The foreign-field trace restores 3,592 distinct fields in 64 pages under derived
quotas. Volatile document fixtures alone do not establish IndexedDB recovery.

`rooms-web-proofs` exercises the production page, including share, issue, edit,
pause, resume, revoke, removal, conflict/focus behavior, reconnect and browser
reload.
The shared-session journey also restarts the actual process peer. Runtime and
external protocol checks cover the underlying execution and baseline consumers.
[Session measurements](../../bench/rooms/session-costs.md) record Host locator
ownership, accept fallback and UI projection costs. End-to-end DM latency is
not measured by those allocation and traversal regressions.
