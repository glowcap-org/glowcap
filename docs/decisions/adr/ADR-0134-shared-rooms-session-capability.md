---
id: ADR-0134
status: accepted
date: 2026-08-25
tags: [rooms, sessions, capabilities, persistence, browser]
decision: "A Rooms session is a capability-owned application runtime that serializes user commands, owns network identity and retained authority, checkpoints one versioned state bundle, and streams revisioned results to every attached view."
supersedes: []
superseded_by: []
amends: [ADR-0133]
amended_by: [ADR-0135, ADR-0137, ADR-0138, ADR-0139, ADR-0141]
---

# ADR-0134 Shared Rooms session capability

## Context

A browser can reconstruct a workspace from a saved document, but reconstruction creates a new set of directory and room
connections. Two browsers that load the same document are therefore two peers. Synchronizing their local storage does
not make them the same member, and nickname retry cannot repair that identity split.

The desired interaction is closer to attaching another terminal to a running session. Every attached screen should see
the same rooms, direct conversations, history target, capabilities, and operation results. An action from one screen
should commit once and appear on the others without each screen performing the network effect again.

## Decision

A Rooms session owns the application runtime above CapTP. It holds directory sessions, room memberships, direct
conversations, remembered capabilities, the selected archive, and the revisioned workspace. A browser view attaches by
holding a session capability. Possession grants the ability to observe that session and, when the facet allows it, send
commands to it.
The shared session, not the attached browser or the workspace DTO, is the live
capability holder. It keeps those holdings while every view is detached, like a
network bouncer keeping a client's presence. A saved sturdyref in its checkpoint
is separately dormant bearer authority; it appears there only after an explicit
retention act and is re-enlivened into the runtime holder on reconstruction.

The durable root mints attenuated observe, interact, and admin facets. A holder can pass one through ordinary OCapN
handoff. Each grant has a separate revoker. Revocation blocks later calls and drops that facet's watcher without changing
the session or another view; an external effect already admitted keeps its durable pending/commit owner. No account role
or ambient login is consulted. The reference is the authority and its interface is its scope.
An eventual account object may hold or issue session grants and durable nickname
claims, but remains a separate capability above this contract rather than an
ambient owner silently consulted by it.

Commands name user acts, not store patches. The session admits a command exactly as written or refuses it without an
effect. Suggestions are separate results. Pure state commands serialize at one turn boundary and advance the checkpoint
revision. External effects first commit a small pending-operation record, then either commit or remain explicitly
unresolved without automatic retry. A command carries a client operation ID. The durable recent-operation window
deduplicates ordinary reconnect retries within its stated bound. Result-bearing authority effects retain their recovery
record until resolution. The session does not claim indefinite UUID deduplication after a completed row leaves that
bounded window.
Live-target preconditions run during effect admission, after a committed operation-id retry has been recognized but
before a new pending row is written. A room or direct conversation with no live realization therefore refuses without
inventing an unresolved effect. A failure after that boundary remains conservatively unresolved because the remote
recipient may already have observed it.
Interaction facets express directory and conversation joins/leaves, direct-conversation closure, shared selection and
drafts, scoped standing, ignore and retention choices, join defaults, and connection preferences without granting
checkpoint-replacement authority. Retained archive selection and operations-vault replacement require the admin facet,
because an interaction facet cannot inspect the bearer custody it would otherwise overwrite.
A room join is one typed checkpoint transition. It validates the directory route and requested nickname, adds or updates
that directory, reuses an already-intended room when applicable, selects the conversation, and derives public-room join
defaults from the committed directory. There is no separate command that can save parallel join defaults or a browser
sequence that can commit only the directory half of a public join. A conversation this tab already holds without a
directory name uses that same join card as its gate; Retry does not invent a nickname, and the directory card reports
the grant rather than collecting one. Pressing a directory on the rail, a conversation, or Settings selects that
directory's conversation in this tab; the directory card still opens from that conversation's title. The
title's close mark on a room, a direct line, or a directory asks to leave in that conversation's card,
rather than acting from the header. Directory
conversations are a view, not a checkpoint row, and the workspace document does not persist them. Their
address still names which directory is showing, using the same `?dir=` a room on another directory uses,
so two directories cannot share one link. The view is a command surface for that directory: slash
commands run there and their results stay in that log. It is not a chat, and there is no directory post.
Opening a direct conversation likewise creates and
selects it in one transition, while creating a direct solely to deliver an invitation deliberately preserves the current
selection.
The browser controller keeps positional command names and argument arrays private. Attached UI adapters call typed
domain methods, so only the controller translates nickname, standing, retention, connection, archive, and conversation
acts into the wire command envelope.

An external effect that mints durable authority has an additional commit requirement. A typed, bounded result record
retains the intent and returned authority before a small apply marker names the next checkpoint revision. The checkpoint
snapshot follows that marker, and startup replays a marker that reached disk first. Finalization removes the pending row
only after the checkpoint is durable. The journal never stores a live reference or a complete checkpoint copy.

Private-room creation carries an opaque client-minted recovery key to the directory. One directory capability call
persists and returns the room sturdyref derived from that key, so retry and restart return the same authority without a
temporary live room between creation and publication. The effect records that result and applies the retained label,
directory, stable conversation id, room link, and selection together. While one
result-bearing effect is pending, another result effect waits, but unrelated checkpoint changes continue. Result
application checks the latest checkpoint for a typed conflict, binds the exact returned authority by digest, and marks
the next revision before writing it. The admin facet exposes a redacted recovery row that can Resume the idempotent
effect or Abandon it before authority returns.
The session checkpoint uses the versioned Rooms state bundle from ADR-0133. Import validates and stages a complete
checkpoint before replacing the live session. Export redacts bearer capabilities unless the holder explicitly asks to
include them. Clearing a checkpoint, clearing message history, releasing a running session, and resetting server-side
Rooms authority remain separate operations with separate confirmations.
Rooms durable capabilities have one copyable URI encoding: the Goblins-compatible unpadded base64url sturdyref form.
That application format does not vary with the CapTP profile of the session that happened to request a room link,
moderator capability, archive, visualizer, or session grant. After parsing that canonical form, the adapter re-encodes
the same Swiss bytes only when a live session API requires its negotiated profile's spelling.
An empty checkpoint remains an established, attached session. The browser may present the directory advertised by its
own page as view-local default context, but that directory enters the durable checkpoint only when the holder explicitly
joins it; reset neither re-adds attachment-origin state nor makes the portable session depend on one web origin.

A newly created durable session records workspace adoption as `available`. Its admin facet may atomically adopt one
complete browser checkpoint, after which adoption is `closed`; retrying the same operation id returns the committed
revision. Every other successful checkpoint commit also closes adoption, including a commit whose checkpoint is
intentionally empty and a result-bearing authority commit. Starting the peer with `--checkpoint` uses an ordinary
replacement and therefore closes adoption before the sturdyref is announced. This is durable lifecycle state, not a
conclusion drawn from revision zero, an empty document, or any other incidental checkpoint shape.

The current snapshot wire contract is one exact twelve-position tuple. Its
eleventh access envelope is version one and always carries facet rights,
workspace-adoption state, and the bounded grant view. The final position carries
runtime-held room offers without serializing their references. Archive and
directory views occupy their fixed positions even when empty. No tuple-length
or missing-field fallback represents an older prerelease shape.

The operations capability vault is edited as one scoped set. Switches and the canonical `ROOMS-*` text are two
projections of that set, not independent acquisition paths. Enabling one switch collects its bearer in a focused modal;
the set commits to durable storage once before live capabilities reconcile. A refused live take leaves the requested
saved bearer visible for correction, with one capability-named failure, rather than rolling back unrelated accepted
entries or repeating a storage write per capability. The editor replaces the home directory's set and the one app-wide
visualizer entry. Credentials scoped to another joined directory remain untouched.
Settings presents this vault with the other Holdings: live session possession,
saved room entry and management authority, the selected archive capability, and
session access grants. Session remains about storage ownership and retention
policy, while Reachability owns locators and connection choices. This prevents a locator or preference from reading as authority and a
saved bearer from reading as ordinary configuration.

The shared session owns facts that must agree everywhere:

- directories, registered names, room memberships, and direct conversations;
- drafts, selection, standings, ignore choices, and shared connection and retention preferences;
- room links, room moderator authority, remembered operations capabilities, and archive selection;
- the ordered command revision and checkpoint revision.

Relative preference commands resolve against the checkpoint being committed.
`setIgnoredName(name, "true" | "false")` changes one case-insensitive entry without
replacing concurrent changes to other entries. `setEffectiveStanding(room, value)`
updates the closest explicit room or directory standing, otherwise the global
standing. Clearing a scoped override preserves the existing inheritance rule.
The explicit scope setters and whole-list replacement remain available for
settings and document replacement.

Each attached view owns facts that describe only that screen or device:

- focus, modal state, responsive sheets, scroll position, and file-picker handles;
- object URLs and other browser resources that cannot cross a capability boundary;
- notification permission and presentation state that has no meaning on another device.

The direct-message protocol is independent of which side uses a durable session. Public inboxes and reply routes parse
one receiver grammar for messages, typing, room invitations, and archive shares. A durable session may adopt the reply
route handed over by an ordinary member without losing those sibling verbs, and reconnect replaces that route without
changing the durable conversation identity.
A handed room remains a live runtime holding while its offer is pending. The
snapshot exposes only bounded display metadata. Declining or losing the carrying
direct session retires the occurrence. Accepting is the explicit durability
act: the session asks the room's source for its entry link, commits that bearer
to the checkpoint, and only then releases the transient occurrence. Arrival
alone never mints or persists room authority.
An intended direct conversation does not dial its saved nickname merely because a session restored. Each live nickname
registration receives an opaque directory-issued registration ID. Discovery, inbox offers, reciprocal requests,
introductions, and the durable conversation record carry that registration ID; an introduction succeeds only while the named registration
still has it. A later holder of the same nickname therefore cannot inherit the old conversation or its history. The
registration ID is comparison data, not bearer authority or a durable account identity. A peer that re-registers receives a
new one and starts a new conversation unless a future account capability proves continuity above this contract.
The watch baseline returns rooms, registration IDs, and its omission count as one bounded snapshot, so startup
cannot lose a registration between an asynchronous replay notification and the room baseline.

Introduction is direction-independent. After an ordinary outbound introduction cannot dial the target's advertised
carrier, the requester may ask the directory to notify that registered target; a client that opts into reciprocal setup
opens the compatible carrier and hands the requester a reply capability with `directReady`. A successful ordinary dial
never raises the fallback, so compatible peers do not race two routes. The control act carries no message and creates no browser conversation or history.
The first real message or an explicit local open owns presentation state. Requests are coalesced per live registration,
removed with that registration, and bounded again by the target's direct-route ceiling. The directory never carries a
direct message or adopts the reply capability.

One route owner arbitrates outbound and reciprocal establishment. A route already live wins; a concurrent loser is
released or closed, and a route generation is captured when its line id is allocated so replacement cannot file an old
line under a new archive generation. Incoming attachment custody records the exact CapTP session that delivered each
occurrence rather than fetching through whichever outbound route is current later.
Normal dialing and reciprocal waiting are one bounded opening per conversation, so commands from several attached views
join the same attempt. A topology change or directory teardown rejects that owner and waits for its dial cleanup.
Incoming direct files materialize once for archive and attached-view readers under one process-wide byte and file ceiling.
Removing a file retires its retained buffer, while an already-admitted read remains counted until it settles.

Files selected in one view remain there until a command transfers their bytes or a hosted blob capability to the
session. A checkpoint never invents persistence for those handles.

The browser workspace envelope separately names its controller: not established, local reconstruction, an attached
session sturdyref, or this tab hosting the session actor. No directory or room interaction is rendered before that choice is established. Fresh and explicitly
detached browsers use one session-establishment surface; a failed saved attachment returns there with its bearer and
failure intact. Settings gives session choice and recovery their own tab, while workspace export, import, and clearing
open in a focused nested modal. Each state action follows the established controller: local mode mutates this browser's
session document and archive, while attached mode mutates the durable session checkpoint and leaves browser-local or
separately selected archives alone. An attached export must not substitute a browser cache when the durable controller
has supplied no checkpoint. Continuing locally from an attachment is an explicit fork of the latest shared checkpoint,
not a return to an independently preserved local session. The fork copies reconstructible rooms and settings. It does
not copy directory names: those remain granted to the session that still holds them, and reconstructing with that
intent would retry another peer's identity. Leaving an attached session for setup likewise drops those names from the
leftover document, so a later local reconstruction cannot retry them. Copied rooms therefore appear without claimed
membership until this browser joins under a name of its own. That selector is neither shared checkpoint content nor device
presentation state. The browser exposes that selector as one discriminated controller value. An attached value carries
the exact sturdyref used for reconnection, and Session settings presents it as bearer authority that can be copied. A
hosted value also carries that sturdyref, naming this tab as the listener. Reloading ends sharing: the wasm Host identity is not persisted, so the next load is local reconstruction rather than a dial of a dead peer. A
local value carries no sturdyref because local reconstruction is not a published durable capability. A complete export
may carry the attached-session bearer; an ordinary redacted export changes the selector to local reconstruction. Adding
this field changes the current prerelease schema. Until a released format exists, stale development documents are
refused rather than migrated.

The session actor binds onto a running CapTP Host through a document store and an advertised locator. The shipped
durable host is a standalone Deno peer that reuses the current Rooms client and runtime and writes `session.json`,
`effects.json`, `grants.json`, and `bridge-secrets.json` (ADR-0141). A browser tab can bind the same actor onto its
wasm Host for the life of the tab:
the session sturdyref names the same locator this tab already advertises for direct messages (WebRTC by default,
`noise-relay` when Settings or `?dm=relay` chooses the sealed relay). A WebRTC session door also names the directory
that served this page, as a `signaling-directory` hint, so Attach can `signalOffer` there even when the attaching
browser was served by a different directory. A leftover membership on the attaching tab and the store's workspace
home are not that inbox. The browser WebRTC connector binds that designator as the
verified channel key before CapTP bytes move, the same signaling-scoped claim
native `authorizeRemote` records (ADR-0105), so Attach can enliven the session
sturdyref. Cross-directory attachment composes several independently bounded
stages: signaling-directory dial and bootstrap fetch, registration, WebRTC
signaling, the CapTP handshake, capability enlivening, and the first watch.
Each stage has its own bound and refusal. Transport stages receive the deadline
as cancellation; CapTP asks cannot be cancelled, so a capability arriving
after its caller's deadline is returned to the session that transferred it.
The aggregate cleanup deadline is larger than those sequential bounds, so it
cannot erase the owning stage's refusal merely because attachment used more
than one network path. After Share, the hosted runtime keeps this tab's live directory sessions — the same Host
sessions DMs already signal through. It re-registers each stolen session under the name the
directory already granted this tab, so hosted DM callbacks replace the UI ones, then files the
WebRTC answering inbox Attach looks up. Re-register withdraws the previous intro; the UI presence
path must not file a second inbox on the stolen session, because that later file races the replace
and can leave the directory holding a dead answerer. Only a failed Share closes unused stolen
sessions. Share waits until this page's home directory is live under a registered name before the
sturdyref is shown; a membership on another directory is not that inbox. Joining a room on this
page's directory is that registration. The attacher uses a live session on the named directory when
this Host already holds one, and otherwise registers there only to be admitted to signaling; it does
not take up the hosted session's rooms under this tab's Host. The hosting tab does not join the
attaching browser's directory. Session documents stay in memory for that tab; IndexedDB is not a session store. Closing or
reloading the tab ends sharing. Connection choice and checkpoint replacement on this tab therefore commit in place:
those acts reload an attached client, and a reload here would end the session. The implementation language and host
location do not change command, event, checkpoint, or view semantics.

## Reactivity and failure

Checkpoint changes carry their revision. Each watch carries a source and sequence over a bounded per-view event queue, so
a slow view detects a gap without pretending transient lines are checkpoint mutations. The durable archive reconciles
missing room lines by the archive's source, conversation generation, and record identity. A room's numeric line id
remains live edit authority and is never used as durable identity across reconnects. Operations mutations use a separate
scoped invalidation event, so held
operator views refresh from committed server state without changing the checkpoint revision.
Before the browser projection binds, its bounded initial event tail reports overflow through that same gap path rather
than silently presenting the retained suffix as complete.

Losing a view does not end the session. Losing the session host ends its live network identity; an attached view may
reconnect to the same host or start a new session from the last committed checkpoint. Those outcomes are distinct in the
interface because a reconstructed session is not the same running peer. Initial attachment races the first complete
snapshot against connection termination and a whole-opening deadline, so an already-ended or unreachable CapTP pair
never becomes the established controller. A connection that finishes after that deadline is retired by the opening
owner rather than leaking behind the establishment screen.
After establishment, one loss retires the old pair, combines any close refusal as a secondary failure, publishes one
disconnected result, and only then schedules the bounded reconnect. Snapshot, line, and operations callbacks carry the
connection generation that registered them, so a retired pair cannot overwrite its replacement.
The browser verifies a new controller selection over a temporary connection, commits that selection while the
connection is live, and retires it before reload. Startup therefore never races the verification pair for the same
session relationship.

## Performance boundary

One state command produces one bounded checkpoint change. External-effect prepare/commit writes only the small effect
ledger, never the whole checkpoint. Browser checkpoint serialization is coalesced and never runs once per transient
presence callback. Snapshots, attached views, reconnect work, and capability inventories have explicit limits. Slow
views detect an event gap and resnapshot. They do not retain an unbounded queue in the session.
An effect that needs a live room or direct route uses two-phase admission. Durable state first recognizes committed or
unresolved retries and validates the caller's revision, then releases its serializer while the runtime realizes the
target. State is re-entered only for a synchronous current-target preflight and the pending-effect write. A slow or
unreachable peer therefore cannot block drafts, selection, settings, or commands from another attached view.

The attached view updates its local draft immediately and coalesces remote draft persistence over a short input window.
It stages that value with the controller before the delayed command, so an intervening remote snapshot cannot overwrite
newer local typing. Every attached composer edit uses that owner, including a message-toolbar mention and recalling the
last submitted line; neither inherits the local workspace's store-only mutation.
IRC projection intent has three states: an absent value keeps the bridge's automatic projected seat, an explicit null is
the durable Rooms-only choice, and an identity requests that exact nick and optional account. Changing the latter two is
reconciled on the live room membership and never tears down or reselects the Rooms conversation. The command waits for
one live attempt, while a failed attempt remains visible beside the saved intent. A service-forced rename fails the IRC
projection instead of silently replacing the Rooms name, and names registered-account login as the likely remedy.
Structured IRC seat updates with no text update roster state without becoming empty timeline lines.
Starting a send cancels that pending draft write, because the send and its final empty draft become the next durable
acts. This keeps one disk checkpoint from being written for every keystroke without delaying local typing.

Checkpoint revision is global, but network reconciliation is not. Command admission labels a checkpoint change as
presentation, standing, or realization work. Presentation changes update the retry checkpoint without walking the live
topology. Standing changes update only room standing. A route, registered name, or room-membership realization change
reconnects only the affected directory; unchanged directory sessions and the operation capabilities fetched through
them remain held.

The network effect happens once at the session owner. Fan-out copies only bounded presentation records to attached views.
File mutation effect identities include the exact content digest and dimensions, so two same-named files with different
bytes cannot alias one retry reservation. Observe facets are refused before file-send or refile authority is consulted.
Archive contents remain in the selected archive and never enter the checkpoint or a session snapshot. Archive shares
cross the session capability in bounded pages even though the browser convenience call assembles their bounded result.
An archive write takes its byte lease when the line is admitted, before live room or direct custody may withdraw or evict
the file. Direct files reuse their already materialized bytes; other readers materialize once. Pending archive attachment
leases have an aggregate memory ceiling, beyond which the line remains archived with file metadata and an explicit
archive issue rather than retaining unbounded process memory or claiming bytes were durable.

Turning history retention off erases the session-owned archive after all already admitted writes without rewinding its
cursor. A selected remote archive has no erase verb, so the same act stops later writes there without claiming to erase
that separate authority.

## Consequences

The current browser peer is separated into a session controller and an attached view. `session/local.ts` is the local
controller selected today. The existing `Peer` command surface and store subscription are the adaptation boundary:
commands move behind the durable controller, and store changes become revisioned view events.

Name registration no longer needs automatic suffixing to make two tabs connect independently. Both tabs control the same
registered member because only the session owner holds that registration. The checkpoint's nickname is requested intent;
the footer and self-identity checks use only a live directory grant and clear immediately when that realization ends.
One session may span multiple directories, each with its own requested and live nickname. Releasing one claim keeps that
directory and its saved conversations in the checkpoint as unrealized intent; the unnamed directory can still provide
discovery and scoped operations without pretending to hold room membership or a direct-message identity.

Local-storage synchronization remains useful for checkpoint durability and explicit import, export, and clear. It is not
the live mirroring protocol.
