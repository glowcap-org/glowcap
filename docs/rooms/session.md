---
type: static
description: Who owns what in the Rooms managed session across Loam, Rust, and React, and how it starts and recovers.
sources:
  - resource: /apps/rooms/rust/application/src/content/session/
  - resource: /apps/rooms/rust/runtime/src/session/
  - resource: /apps/rooms/rust/browser/src/
  - resource: /apps/rooms/rust/platform/src/storage/session.rs
---

# Rooms session ownership and recovery

A Rooms session is what a person keeps across devices: their identity, rooms,
direct conversations, drafts and history settings. The same Rust code runs it
in a server process and in a browser tab.

Loam stores the session's content, the capabilities it holds, its access
grants and the receipts for its changes. Rust makes every decision, and React
shows the result and sends the reader's actions.

The [shipped inventory](../../apps/rooms/shipped.md) describes product behavior.
The [roadmap](../roadmap.md) tracks room, directory and archive authority
work beyond the session.

## Owners and consumers

Paths in this table are relative to `apps/rooms/`.

| Surface | Owner | Contract |
| --- | --- | --- |
| Declarations | `rust/application/src/content/session/` | Workspace, held-storage and effect codecs. Permission requirements, presets and generated browser metadata. |
| Runtime | `rust/runtime/src/session/managed/` | Source admission, atomic storage acquisition and receipts, supervised workers and bounded readers. |
| Process | `rust/platform/src/storage/session.rs`, `rust/services/src/session/`, `rust/product/src/bin/rooms-session/` | SQLite bootstrap, stable independent use/control publications and typed local-control operations. |
| Browser | `rust/browser/src/attached/managed/`, `rust/browser/src/storage/` | Per-tab IndexedDB bootstrap, exact saved fields and retained Wasm handles. |
| Clients | `rust/glowcap/src/client/workspace/`, `rust/glowcap/src/client/access/` | Local and remote workspace calls, retained requests and independent management. |
| Page | `web/ui/session/managed/`, `web/ui/main.tsx` | Projection of requests and activity, drafts, navigation, history, files and explicit recovery. |
| Access editor | `web/ui/settings/` | Separately held controls, permission groups, revision-checked changes and descriptive inventory. |

The [effect contract](session-effects.md) covers how a change is admitted,
sent and settled. Local and remote calls go through the same typed clients on
the shared Host. Opening a session locally needs no relay, and publishing it
sets up reachability only when needed. A control from another session keeps
its route to that session's owner.

## Shutdown

A JavaScript handle that changes the session works only while its Rust owner
lives. Committed receipts stay in shared storage either way.

- A callback that shuts down keeps its admission until the exact seat or name
  it was admitted through is retired. If it cannot tell whether it was
  admitted, it refuses to clean up.
- A failed browser close keeps the owner so the close can be retried.
  Disposing of the handle gives up that retry.
- Managed inboxes close before the session's attachment and Store.

## Storage and startup

`managed::Opened` owns the callback, receipt workers, attachment and Store,
and closes them in dependency order. Before it publishes the session's use and
control references, `managed::Bootstrap` saves the identity, provisional
metadata, the resource commit and a separate live marker. Reopening recovers
the original branch derivation. Startup checks workspace and receipt metadata
without restoring every held field.

The server process uses SQLite, atomic replacement of metadata files and a
directory lease. The browser uses per-tab IndexedDB metadata and the Store's
exclusive Web Lock. Replacing metadata compares the previous bootstrap in the
same transaction, so a slow preparation cannot overwrite a confirmed root.
Browser metadata and Loam both require strict durability. Startup refuses
when a confirmed root is missing or storage is uncertain.

Workspace choices, held storage and receipts commit together as one registered
codec graph, and shared sizing sets the record and graph budgets. A strong
field keeps the exact grant and target generation, and typed coordinates name
each field. A nickname, row ID or serialized view grants nothing. Acquiring a
bearer link is an explicit step that saves the resulting capability.

Browser readers share the newest accepted workspace revision. A late reply
carrying an older one cannot roll back the screen or the snapshot a command
is built from. An editable candidate copies that snapshot before changing it.

A fresh Host start retires old registrations, direct routes, callbacks,
publication leases and line edit selections before anything can reach it or
supervision starts. Nickname choices, drafts, history identity, introduction
witnesses and original receipts stay. The live marker keeps observations from
an earlier run out of the new one. <!-- status-allow: runtime state or operation ordering -->

## Completion and recovery

Checking a change's status, reading its receipt or adopting its result needs
the original change's permissions and its exact source witness. A
collaborator can finish their own drafts and actions. Listing pending changes,
recovering the original request, resuming its executor and releasing a
receipt all need `ResolvePending`.

A receipt can be final while its executor is still held, when the outcome
commits before the worker sees the reply. Recovery carries that same executor
through settlement and cleanup and never sends the action upstream again. An
unknown receipt found cold has no executor to resume, so it stays unknown.

Saving the result of a posted line or a direct introduction needs only the
original participation permissions. It installs that one result, leaves other
workspace choices alone, and checks the returned identity, held targets,
releases and source. If the workspace changed underneath it, it reports a
conflict before saving anything. Saving any other result still needs
`ManageCustody` and a workspace replacement.

Activity delivers message text and attachment details apart from the file
bytes. A refused file read stays with that attachment, and opening it again
retries the same selection. The refusal does not stop messages from arriving
or grant permission to read the bytes. An expired selection is refused rather
than replaced with another file.

## Membership and direct-message lifetimes

Each directory, room and direct-message row keeps the session endpoint that
created it, and a worker restores that endpoint and the row's targets when it
starts. Installing a row, registering or subscribing, and saving a returned
capability each commit the actual callback with its selection. Replacing an
inbox, source, entrance or registration fences off that callback and retires
its worker. A room whose directory registers a nickname joins only after that
registration lands, because the registration would fence a seat taken before
it.

`Memberships::reconcile` leaves sibling workers and shared fields alone. One
`WorkspaceActivity` observation drives all of them:

- Private content and grant changes wake workers to recheck their sources.
  The wake carries no content or authority.
- Final executor progress wakes receipt readers even when no content changed.
- A standing reconcile reuses the snapshot from its wake.
- At startup, how many candidates are admitted does not depend on live inbox
  capacity.

Removing a row asks for it to be retired. The session keeps its task until
replies drain and it has left upstream, and a failed cleanup keeps its exact
state for a retry. An interrupted wait keeps its original receiver, and a
subscription with an unknown outcome stays unresolved. Cleanup never removes
a newer registration or membership that replaced the old one. <!-- status-allow: runtime state or operation ordering -->

A direct worker publishes the inbox it actually created for the other member.
An introduction checks registrations on both sides and keeps the original
witness in its receipt. Reconnecting replaces saved live connections, and a
late adoption cannot override newer navigation. An incoming notification
cannot reopen a closed conversation. Removing a closed sidebar entry records
its departure in the workspace.

The viewer starts waiting for the other side before it asks for an
introduction, so an early notice is not missed. Only the original directory,
registration and opening can satisfy that wait. A pending introduction gives
up locally after <!-- value ../../apps/rooms/web/ui/session/managed/readiness.ts READINESS_WAIT_MS milliseconds -->30 seconds<!-- /value -->. Closing the viewer, cancelling or reaching
that deadline ends the wait without sending another introduction, and does
not cancel an admitted change or discard its receipt.

When you send, the composer moves your text and files out of the editable
draft into a fixed plan. Typing after that, and later sends, are separate, so
saving a result cannot clear a later draft. Recovery names the original
operation, and a second message with the same text cannot be mistaken for it.

## Discovery, signaling, archives and bridge secrets

A directory reader keeps the viewer's own access grant and the directory it
reads. `ObserveWorkspace` allows named reads through access shared
separately. Pausing or revoking that grant also stops its readers.

- Background discovery workers keep the directory source that started them.
- Looking up a public name can find a durable room with no members.
- A publication witness describes the current generation and reveals no
  secret part of a link. Private rooms have no public witness.

Signaling keeps the exact directory, registered name and source that started
it. Its wrapper rechecks that selection, and the room server refuses a name
that expired or was replaced. Browser listeners own their own cancellation
and shutdown. The saved connection choice decides whether to advertise the
relay or WebRTC.

The session process keeps one checked signaling route per directory it is a
named member of. Started with `--dial-transports=webrtc`, it dials a member
that advertises WebRTC by carrying the offer, answer and candidates through
the directory that introduced the member. It also listens for WebRTC: it
registers its WebRTC locator, with its own listener's locator as the
fallback, and files an answering inbox through each route. An offer that
arrives there names the Host key in the member's registered locator, and the
accepted session is pinned to it. A member whose locator names an address or
an iroh node has no Host key there, so its offer is refused. `--ice-servers`
names the STUN or TURN servers both directions gather candidates through.

History reads the selected archive, or this session's own recorder when none
is selected. Archive reads have their own permissions and go through a file
reader the archive controls. Turning off recording erases that recorder's
history before the change completes, as the
[archive guide](../../apps/rooms/rust/archive.md#recording-in-a-session)
describes.

A bridge command keeps its exact origin and recovers the bridge password only
through the original witness. A form reader shows only what the bridge asks
for and rechecks the original session source. Fetching the password and
running the command have separate owners.

## Management

Using a session and managing it are separate capabilities. A control held on
its own can carry Inspect, Issue, Edit, DelegateControl and lifecycle powers.
Shared Loam declarations decide which powers depend on others and which apply
to each kind. Labels, inventories and IDs only describe access and cannot
rebuild a control.

Edits and new grants check the revision they expect. Issuing a grant advances
the source's revision, so the next issuance rereads the source first.
Replaying the exact same request returns its original receipt before an old
revision is treated as a new request. A new grant can carry every management
power the source can pass on, and what it may edit is capped by both the
source's edit and issue limits. Sharing management creates a separate,
narrower control with the chosen powers.

Revocation ends access for good. Its grant record stays as a tombstone, so an
old link or ID can never reach access issued later, and the issuer's inventory
lists it as revoked. Revoking from the editor also removes its row. Removing a
row is a separate act that releases the saved row and leaves the access
untouched. A live row asks first, because removal gives up the only way to
manage it from this workspace. The workspace's own control is never removed.

The editor keeps requests with unknown outcomes and keeps drafts on conflict.
A finished grant clears its pending form. Separate action keys stop a
finished button from submitting a form in the same click. A control without
Inspect shows only the label and permissions this viewer knows it saved.
Powers fixed when a grant is issued cannot be added later.

## Evidence and costs

The storage and change tests close and reopen real storage on Linux/SQLite and
Chromium/IndexedDB, and check receipt replay, unknown commit outcomes, source
loss and capacity refusal. The proofs that reopen a session store also run on
LMDB. The [foreign-field trace](../../apps/rooms/shipped.md) holds the
restore counts.

`rooms-web-proofs` drives the production page through share, issue, edit,
pause, resume, revoke, removal, conflicts, reconnect and reload, and restarts
the process peer. The release image proof recreates the session container over
its saved volume and checks that the iroh locator and both publications
survive. [Session measurements](../../bench/rooms/session-costs.md) record
locator, accept and UI projection costs. End-to-end DM latency is not measured.
