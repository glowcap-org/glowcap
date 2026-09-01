---
id: ADR-0135
status: accepted
date: 2026-08-25
tags: [rooms, persistence, capabilities, schemas, architecture]
decision: "Rooms state is an authority graph whose durable JSON documents and bounded JSON DTOs have schema-inferred types, while live capabilities remain with the runtime owner that can exercise and retire them."
supersedes: []
superseded_by: []
amends: [ADR-0129, ADR-0133, ADR-0134]
amended_by: [ADR-0136, ADR-0137, ADR-0138, ADR-0139]
---

# ADR-0135 Rooms state authority graph

## Context

The Rooms application has several kinds of state that meet in one interface but do not have one owner. A directory
grants names and publishes rooms. A room owns its live membership and line authority. A member archive owns an observed
history account. A durable Rooms session owns the user's intended workspace and the network references that realize it.
Each attached browser owns only that device's presentation resources.

Treating those facts as one nested session document would copy authority into data and confuse restart with ownership.
Treating each JSON parser as a local implementation detail would instead create parallel definitions of the same rows,
bounds, and format rules.

## Decision

Rooms models state as an authority graph. A reference between domains is one of four things:

- plain data that can be validated and replayed without granting authority;
- a sturdyref that can reconstitute authority through OCapN;
- a live `Ref` whose authority and lifetime stay with its runtime owner;
- an attenuated or revocable facet minted for the exact access being shared.

The capability holder is the application session, not an undifferentiated
workspace. A browser-owned session holds live references until that runtime
ends. A shared Rooms session is the bouncer-shaped sibling: its runtime keeps
holding directory, room, direct-line, archive, and operations capabilities
while any particular browser is detached. Detaching a view releases that
view's facet and watcher; it does not release what the shared session still
holds. Clearing or retiring the shared session is the explicit act that gives
up those holdings.

A sturdyref saved by an explicit retention act is dormant bearer authority,
not harmless configuration. The storage owner holding those bytes can
reconstitute the capability later and must present, export, and erase them as
secrets. A locator, requested nickname, room label, or desired connection is
reconstructible intent and grants nothing by itself. “Workspace” describes the
user-facing aggregate; its established session controller decides who owns the
live references and which bearer values were deliberately retained.

Persisted JSON documents and bounded JSON DTOs use Zod schemas as their structural authority. Public TypeScript data
types are inferred from those schemas. Cross-record checks remain beside the aggregate schema that owns them. Positional
CapTP tuples, `Session`, `Ref`, byte streams, timers, browser files, and other live resources keep explicit domain types
and parsers. A JSON schema never becomes the authority for capability lifecycle or wire protocol semantics.

Schema dependencies run from shared bounded primitives into domain schemas, then aggregate documents, controllers, and
view projections. A standalone session checkpoint does not depend on a browser workspace envelope. The workspace may
contain a session document, but it does not define what that session document means.

| Domain                | Durable document or bounded DTO                                                                                                         | Runtime state that stays out                                                                            | Reconstitution and authority                                                                                                                                                                                                                                                                                                                                                                                                 |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Server authority      | `rooms.json`: Host seed, room-link secret, active and revoked room identities, room-link, manager, moderator, and public-entrance generations, managed room policy, and room topics | Host, sessions, publications, registries                                                                | The server derives and republishes the same current room, manager, and moderator sturdyrefs. A passable room manager governs only one room's public registration and admission policy while retaining no live room. The registered name remains reserved and reconstitutes that room on named entry after it empties. A room link grants entry but neither name ownership nor management. Unregistering withdraws the public entrance and moves the room to private access without revoking its room link, moderator, manager, or live memberships. The same manager may register it again if the public name remains available. Tombstoned generations prevent revoked authority from returning. Topics follow stable room identity across registration changes. |
| Server operations     | `operations.json`: operator-requested listener options, IRC network configurations, channel leases, and bridge publication and moderator generations | Listener sockets, accepted sessions, IRC sockets, reconnect timers, bridge seats, and live room capabilities | Startup restores source-owned bridge entry and moderation publications plus network authority before its channels. A network with no channels enacts no transport. Down, part, and network close commit removal before retiring the live resource. Controlled shutdown closes resources without deleting replay intent.                                                                                                                                                                 |
| Directory             | Bounded publication and reachable-peer view DTOs, plus operator and operations DTOs                                                     | Granted nick claims, registrations, signaling exchanges, and peering leases                             | Claims are connection-scoped capabilities. A durable session remembers the requested nick and claims it again. Presentation names only the current live grant and clears it on disconnect or refusal. Each connected directory owns one bounded live discovery projection for attached views.                                                                                                                                |
| Room generation       | Versioned retained-history rows, public or authority-coupled durable topics, and bounded live room-view DTOs                            | Members, inbox and topic refs, line refs, uploads, file capabilities, timers                            | Membership is resubscribed. A room sturdyref or directory publication grants entry. Roster and attachment capabilities are current room facts rather than checkpoint data.                                                                                                                                                                                                                                                   |
| Member archive        | `peer.json`, bounded archive JSONL entries, content-addressed blob files, and IndexedDB record and blob rows                            | Archive refs and in-flight writes                                                                       | The selected archive is a separate capability. Source, generation, and record id preserve record identity across reconnects; scoped blob readers grant retained byte access.                                                                                                                                                                                                                                                 |
| User workspace intent | Versioned session document inside a versioned browser envelope                                                                          | Presence, transport sessions, object URLs, browser files                                                | Directories, requested nick claims, rooms, DMs, drafts, selection, preferences, and peering intent are replayed as intent. Room, archive, session, and operations sturdyrefs enter only through explicit bearer-retention acts. The established controller decides whether the browser session owns that document or it is a projection of a shared session checkpoint.                                                                                                                  |
| Durable Rooms session | Session document store (`session.json`, `effects.json`, `grants.json` on the file host), command DTOs, and bounded snapshot DTOs | Live directory sessions, room and DM refs, attachment and archive-share refs, archive ref, watcher refs | The session capability is the movable authority to the shared application session, which remains the live holder while views detach. Observe, interact, and admin sturdyrefs are bounded, restart-stable, and separately revocable. `session.json` explicitly records whether one initial browser workspace may still be adopted; checkpoint contents and revision never stand in for that fact. Attached views project checkpoint revisions and bounded live facts without repeating network effects. |
| Attached view         | Browser envelope controller choice                                                                                                      | Focus, scroll, modals, file handles, object URLs, notification permission                               | Session establishment precedes the Rooms application. These presentation facts belong to one device and are rebuilt locally.                                                                                                                                                                                                                                                                                                 |

A saved nickname records the user's requested claim. The directory remains the authority that grants or refuses it. A
saved direct conversation names the directory, displayed peer name, and directory-issued registration ID. The ID
prevents reconstruction from retargeting the conversation to a later holder of that name, but remains comparison data
rather than global identity or bearer authority. A stronger person identity must arrive as a capability or authenticated
identity claim, not as another string field.

A browser envelope may cache the latest attached checkpoint so it can render and explicitly fork that state locally, but
the cache is never an alternative authority while attached. Import, reset, and export dispatch to the established
controller. A missing attached snapshot is an unavailable shared state, not permission to operate on the cache under the
same label.

Workspace adoption is a one-time durable session transition, not schema normalization. A new session begins with
adoption `available`; the first adopted or otherwise committed checkpoint makes it `closed` permanently. An
intentionally empty established checkpoint remains closed. The snapshot projects this state so an attaching admin view
knows whether to offer its local checkpoint, while observe and interact facets have no adoption verb.

The aggregate session schema owns relations between those rows. A room or moderator sturdyref must name the recorded
directory, moderation cannot outlive its room link, a member cannot open a direct line to their own claimed name, and a
directory has at most one live direct route per registration and one public membership per room name. Leaving a peering
source or destination removes the dependent publication intent in the same checkpoint commit. One app-wide visualizer
credential is allowed; directory-scoped credentials may coexist and a scoped editor preserves the ones it does not own.

Room-link invitations are reconstructible because their sturdyrefs retain authority. Handed invitations contain live
references and remain runtime-only while pending. Accepting one explicitly asks
its source for a durable entry link before checkpointing it; declining it or
losing its carrying direct session releases it. Ordinary exports remove
room links, invitation links, operator credentials, archive authority, and the attached-session sturdyref. Complete
exports retain them only through an explicit bearer-authority action.

Capability cleanup follows occurrence ownership. Closing the enclosing CapTP session settles releases it has already
reclaimed; any other release refusal is reported while sibling cleanup and the original operation continue.

Room-retained history and the member-owned archive are separate accounts. A session selects and holds an archive
capability; it does not absorb the archive's records into its checkpoint. Attachment bytes likewise require a separate
blob-custody decision and never enter a checkpoint merely because a line mentioned them. Changing the browser archive
target redirects new writes in the same turn, then drains writes already assigned to the old target. Displayed
archived-file occurrences keep a bounded lease on the target that supplied their record, so lazy reads never retarget to
a newer archive. A closed or replaced conversation releases that lease before stale hydration can land. Read failures
reach the hydration owner, and queued write failures enter the bounded page trouble journal without poisoning later
writes.

The session-owned archive is erasable storage, a stronger internal contract than the ordinary archive backend or a
read-only shared facet. Its clear operation preserves the revision cursor and serializes ahead of later local reads and
writes. Remote archive capabilities remain separately owned and are never given an erase verb by implication. An
incoming archive share remains in its bounded owner until release succeeds or its carrying session closes; an unexpected
release refusal leaves an unavailable, retryable row rather than deleting the only cleanup path.

Ordinary effect deduplication has a bounded recent-operation window. The browser does not retry an ambiguous ordinary
effect automatically after that effect reaches its durable pending state. Result-bearing authority operations add an
idempotent recovery key and retain their pending result until it is applied or explicitly abandoned. An indefinite
deduplication claim would require a different compact client-sequence contract and is not implied by the current UUID
ledger. A live durable-session instance also coalesces concurrent execution and recovery of the same result operation;
the durable row may become observable before its original Host call returns, but that observation cannot re-enter the
Host or start the operation twice. This process-local coalescer controls execution only. The durable ledger remains the
authority for restart recovery.

State synchronization follows one rule across these domains. While an authority is reachable, its owner pushes exact
facts into the state owner, which serializes a conditional reducer and notifies attached views without advancing the
optimistic user-command revision. A remote retirement or reachability observation therefore cannot manufacture an edit
conflict; the next command is serialized onto the reconciled checkpoint it actually owns. While disconnected, local
desired state remains intact. Reattachment validates it lazily and sends
the facts it learns through the same reducer. Transient transport failure retains intent and enters bounded retry;
authoritative retirement clears only the matching bearer and becomes a visible needs-action state. Pushed retirement
names the exact opaque publication generation, so a delayed event cannot erase a later grant. The runtime keeps failed
state facts in one instance-owned ordered retry queue rather than dropping them or creating a process-global registry.
An explicit room recovery is itself two-phase: the checkpoint records `requested`, a fresh realization must succeed,
then the state owner clears the marker without changing the user-command revision. Failure conditionally restores
`manual`, so a public name is never retried in the background after a revoked exact link; a held room requires a current
link because its label has no lookup authority.

## Prerelease formats

No Rooms persistence format has a released predecessor. Each current document therefore uses version one and accepts
only its exact schema. Replacing a prerelease schema keeps version one; stale development state is refused without
rewrite and may be deleted explicitly. A later released format can advance the number only when the application
intentionally supports that older contract.

## Performance boundary

Every file read has a byte ceiling before JSON parsing. Every remote aggregate has a row and field ceiling before
projection. Persisted-document parsing is startup or explicit import work owned by that aggregate. Checkpoint writes are
coalesced, validate again at their storage owner, and carry an explicit reconciliation impact so presentation-only state
does not force a whole-topology comparison. Effect-ledger status has a separate observer path and never asks the runtime
to reconcile an unchanged checkpoint. An administration command that replaces retained capability custody answers only
after the runtime's already-queued reconciliation attempt completes. The answer does not wait for later reconnect
retries; its bounded issue rows are the current result, while the checkpoint remains the intended state. An exception
that escapes a reconciliation attempt becomes the runtime issue and schedules the bounded retry. A later successful
attempt clears that issue and cancels any older retry timer it made obsolete.

Successful directory watch marks the exact saved route as previously reached through that same reconciliation seam.
Room-authority and reach reconciliation scan only the bounded session checkpoint; directory connection attempts remain
at fixed concurrency, and a generation check closes a late result before a superseded plan can install it. Reference
sweeps establish one cached search cursor and continue it across bounded calls, so a hundred-thousand-row sweep does not
reallocate or restart the full scan for every batch.

Live directory rows and room members also have whole-snapshot budgets. The snapshot encoder counts UTF-8 text before
CapTP encoding. If live projections would cross that budget, it keeps the durable checkpoint and reports a
`snapshot-overflow` issue while omitting those reconstructible live views. It never lets an observer callback turn a
committed checkpoint into an apparent mutation failure.

A stateful Rooms server, archive peer, or durable session holds an operating-system lock on its state directory. The
lock covers every document and append log below that owner, so two processes cannot interleave otherwise atomic writes.

Zod does not run over hot room notifications or CapTP message tuples. Those parsers validate positional values and
capability occurrences directly. The measured browser cost of the first schema pass is recorded with the Rooms change;
future schema additions remain subject to the page bundle and focused performance checks. Attached operations compare
their bounded credential, connection, and issue rows directly, so an unrelated draft or selection snapshot allocates no
serialized fingerprint.

## Consequences

Changing a state domain means changing its schema, inferred type, format policy, serializer, parser, and focused proof
together. Server, archive, session, and workspace documents may evolve independently because none borrows another
domain's version number.

Moving session storage behind a user-held storage capability does not change the session document. Replacing the Deno
session host with a Zig host does not change the capability facets or DTO schemas. OCapN authority remains the contract;
the storage and implementation language remain replaceable edges.
