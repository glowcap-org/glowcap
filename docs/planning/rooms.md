# Rooms recursive resources plan

Status: active plan. This plan owns the Rooms work that is not built: recursive
rooms and scoped content, restricted directory access, conversation workflows,
and the shared access editor across all of them. The managed session, its
storage, admission, effects, and browser page are shipped and described by the
[session guide](../rooms/session.md), the [effect
contract](../rooms/session-effects.md), and the [page
contract](../../apps/rooms/web/ui/README.md). The
[roadmap](../roadmap.md#durable-applications) owns priority.
[ADR-0183](../decisions/adr/ADR-0183-rooms-scoped-sharing-and-recovery.md)
settles the design. This file is its remaining contract.

## What this depends on

Rooms is an application on Loam. Everything it needs from the
[managed access](../loam/access.md) module ships: resources, scopes, grants,
ceilings, controls, derivation, receipts, observation, publication, and the
C/Rust and browser profiles. Two Loam residuals in the
[open obligations](../roadmap.md#open-obligations-from-retired-plans)
are prerequisites for phase 5's reorganization: cross-resource content changes
in one transaction and a general operation journal. Nothing else here is Loam
work. Shared Zig stays the authority for policy algebra, dependencies,
ceilings, scope, and lifecycle. Rust declares application prerequisites and
selected targets. UI containment never becomes a second parent or authority
map.

This is Rooms behavior carried by OCapN capabilities. OCapN defines no roles,
grant ledgers, invitation policies, or account permissions, and no new CapTP
message, codec rule, identity registry, or transport privilege is needed.
Rooms is unreleased, so no current API, wire method, policy tier, or stored
format is preserved. Stored state keeps schema version 1 under the
[prerelease rule](../../.agents/rules/prerelease.md), and reset is an operator
action, never a loader that converts invalid state into empty or privileged
authority.

## Authority model

### Objects

| Object | Meaning | Lifetime and control |
| --- | --- | --- |
| Resource | An addressable collection, session, or content object with stable identity and typed operations. | Owned by its hosting application. Destruction is an explicit operation. |
| Access grant | A bounded record backing one independently managed grant. | Live or persistent as declared. Policy can change, suspension is reversible, revocation is terminal. |
| Use facet | The capability through which a recipient exercises granted powers. | Every act is checked against the current backing grant and any deliberate parent dependency. |
| Grant control | A capability to inspect or administer one grant or bounded branch. | Separate from use. It cannot name sibling grants into its authority. |
| Access administration | Authority to issue and administer grants for a resource. | Explicitly granted. Visibility or a nickname never supplies it. |
| Offer | An admission under specified authority. | Single-admission or reusable, one-visit or continuing, with its own issue, claim, and retirement state. |
| Live membership or attachment | One active use of admitted authority. | Ends on leave or runtime loss without revoking permission to return. |

Inviting creates access for a new membership. Passing one's own seat delegates
the existing seat. Attaching to another person's session exercises that
session's memberships. The UI and protocol keep all three apart.

### Rules that hold everywhere

- **Each resource owns its grants.** A directory owns discovery, naming,
  publication, creation, and introduction. A room owns admission and its
  memberships' acts. A session owns attachment. Listing a room does not make
  the directory its owner. Revoking one resource's grant never revokes
  independently issued grants on another, and never closes a shared CapTP
  connection. Dependencies between resources are explicit records, never
  inferred from process, name, nesting, or UI containment.
- **One typed grant lifecycle.** A record names its owning resource and
  generation, grant ID, optional parent, target scope, issuance ceiling,
  policy, revision, lifetime, status, and a bounded label. Applications supply
  typed permission declarations and committed content facts. Managed access
  owns validation, attenuation, and effective rights. No per-resource ledgers
  and no string permission map.
- **Ceilings bound edits.** A child's ceiling is at most the authority its
  issuer holds. Expanding the parent later never enlarges it. An edit beyond
  a ceiling needs a replacement grant. A control carries its own management
  ceiling: pausing a child does not authorize raising it, administering the
  parent, or viewing every grant.
- **Copies share, children attenuate.** Copying a capability shares its
  grant and revocation boundary. Issuing a child creates a separately
  identifiable grant with a deliberate dependency. Narrowing or pausing a
  parent constrains descendants at once. Revocation is terminal for the branch
  even before cleanup reaches every descendant. Independent grants survive.
  Nothing can stop forwarding a held bearer, so no "cannot share" switch.
- **Admission uses unguessable receipts.** Competing receipts race for one
  admission. A retry with the winning receipt recovers the same committed
  result. A lost reply cannot mint two grants. Admission records the accepted
  grant before exposing it. Closing an offer and revoking its branch are
  different actions. Single-use or reusable and one-visit or continuing are
  independent choices and all four combinations exist. Timed expiry is out of
  scope. A browser timer cannot expire authority.
- **Public access is a policy-selected offer.** Changing it retires unused
  entrances without touching admitted grants. Revoking a grant is not a ban:
  if public admission or another link still admits, that route stays valid
  and the editor says so. No account IDs, IP bans, or nickname blacklists.
- **Check at the owner of the effect.** Every protected operation uses a
  typed admission result bound to the exact resource, grant generation, and
  committed revision, rechecked after any asynchronous wait and before
  returning new authority. Returned capabilities (topic, file, upload, line,
  history, watch, voucher, signaling, session view) consult their grant while
  they exercise it. Independent authority is explicit in the result.
- **A change has a boundary.** Success means the durable policy committed
  and every new admission observes it. Delivered bytes are not recalled.
  Deferred work rechecks at its commit. Pause keeps a bounded status channel
  and no content. Revocation releases subscriptions and derived resources, and
  a lost notice cannot keep authority usable.
- **Persist before publishing.** Authority commits before it is exposed.
  Retrying an operation ID with the same intent returns the same result and
  different intent is refused. An indeterminate write fences the owner until
  storage reconciles. Publication entropy is domain-separated by resource
  kind, identity and generation, grant, and purpose. Revoked IDs are never
  reused. Logs, traces, and clipboard affordances keep management IDs apart
  from bearer secrets.

## Sharing model

Every shareable resource (session, directory, room, conversation, message,
file, archive) supports two actions.

| Action | Authority received | Management consequence |
| --- | --- | --- |
| Share existing access | Exactly the held reference: owner powers if it is an owner capability, the facet's limits if it is a facet. | Both holders use one grant. Copying creates no recipient-specific control. |
| Create managed access | A new facet with explicit scope, permissions, issuance ceiling, and dependency on the issuer's authority. | Editable, pausable, revocable within that dependency. Equal initial permissions are allowed. |

Resource identity, access, persistence, and provenance are independent
dimensions. A sturdyref recovers a capability without implying owner
authority. A durable limited share recovers the limited facet. Scope (exact
object, bounded set, owned subtree, or declared projection, per the
[shared API](../loam/access-api.md#scope-and-policy)) is part of policy, and a
preset never widens it. A facet over one message withholds siblings and
parent administration. Its returned files, previews, search entries, and
subscriptions keep the same limits. Resharing a facet records a derivation
edge. Forwarding it does not. Across owners, a mediating facet retains and
exercises the upstream capability, so an upstream refusal stays effective, a
partition reports failure rather than a commit, and no mediator can reach a
stronger entrance. The nearest durable ancestor restores descendants whose
state it owns. A share publishes the exact intended capability, never an
ancestor locator with a client-side path.

Ownership: Loam owns records, fields, residency, and transactions. The managed
access core owns identity, containment, scopes, policy algebra, dependencies,
ceilings, and lifecycle. Its hosting layer registers behaviors on the existing
Host. The Rust binding wraps them. `rooms-application::content` owns Rooms
content identities, collections, conversations, messages, placements,
permission meanings, presets, operation requirements, offers, and content
effects. `rooms-runtime` composes content operations with admission in Loam
transactions. `rooms-services` hosts directory and room composition.
`rooms-platform` and `rooms-browser` adapt storage and transport and decide
nothing. The binding's `Session::caretaker` and `Session::attenuate` are
reused where they fit. They supply no persistent policy or content scope. A
separate content crate is not warranted. Portable contract tests use typed
fixtures with no Rooms imports, including a non-chat resource, on Linux and in
Wasm.

## Content model

| Surface | Question | Interaction |
| --- | --- | --- |
| Directory | Where can I go? | Browse, search, and organize entrances. |
| Room | What is happening here? | Participate through conversations. Inspect activity, shared material, and access. |
| Conversation | What are we discussing? | Read and compose ordered messages, reply, branch. |
| Message | What was said? | Read one contribution with permitted context. Reply, share, or edit. |
| File | What was shared? | Preview or retrieve authorized content and metadata. |

A room contains conversations, nested rooms, and shared entries. A directory
lists rooms and may list conversations, messages, files, or other directories.
Listing grants nothing. Managed access owns resource IDs and owned containment
(an acyclic graph within one owner). Content records use those IDs and keep no
second parent map.

| Record | Application-owned content |
| --- | --- |
| Directory | Title, description, discovery and entry behavior. |
| Room | Title, description, room-wide subject, default conversation, participation settings. |
| Conversation | Editable title, open or archived state, message order, optional branch provenance. |
| Message | Author relationship, creation marker, body revision, attachments, optional reply target, withdrawal state. |
| Entry | Stable placement identity, label override, retained capability, disclosed sharing context. |
| Branch provenance | Source conversation and initiating message IDs, plus separately authorized navigation references. |
| Reorganization record | Operation identity, affected IDs, source and destination placements, authorizing context. |

Every published message belongs to one conversation. Appearing elsewhere is a
placement holding a capability, never a copy. Reply targets, branch sources, and
placements define no containment and no authority. Titles are mutable metadata
and a conversation keeps its identity through renames, moves, and branch
changes. Author identity comes from admitted membership or declared author
authority, never from a caller-supplied field.

**Surfaces.** A directory view pages entries with search and organizing
controls. A private target's title is not copied into a public listing. A room
opens its default General conversation, created in the same transaction as the
room. Changing or archiving the default needs room management and a
replacement. A conversation view has a title, ordered stream, composer when
posting is allowed, and a branch panel. Read-only access shows content without
a dead composer. A message link opens a focused view with only permitted
context and no fetched parent. Direct conversations use the same model with
different defaults.

**Replies and branching.** A reply stays in the conversation and records its
target. Branch creates a new conversation from a message, a range, or the
conversation, without moving or copying the source messages, retaining
authorized source references. Where the creator can post to the source, a
continuation entry appears there. A private branch leaks no title, count, or
notification. Reciprocal entries across owners are separate operations with
no distributed commit. The branch tree is a bounded view over provenance.
Reading a source message implies no right to post a marker, create in its
room, or disclose it.

**Sharing elsewhere.** Share here places the exact selected access into a
destination that accepts entries, previewing kind, metadata, audience, and
which sharing action applies. A shared message is a live card with two
distinct replies: Reply in source (needs source posting authority) and
Discuss here (posts to the destination). Quoted text is visibly data.
Revoking a facet leaves a bounded unavailable entry. Caches cannot
redisclose, and switching to an independent capability is an explicit choice.

**Reorganization.**

| Operation | Identity and membership | Access |
| --- | --- | --- |
| Rename | Nothing else changes. | No change. |
| Move entry | Destination gets the held reference and context. The original stays. | Source removal and destination insertion authority. Cross-owner placement is two acknowledged acts. |
| Move conversation | Reparent within an owner. Message IDs unchanged. | Revalidate subtree scopes and destination disclosure before commit. |
| Move messages | Reparent selected messages. IDs, authorship, markers, reply targets survive. | Preview scope gains and losses. Grant ancestry is never rewritten. |
| Split | New conversation plus a move in one owner transaction with provenance. | Creation, source reorganization, destination posting, and any audience change. |
| Merge | Move admitted source messages to one destination and archive sources with continuation. | Source grants never become destination-wide. |
| Archive | Identity and readable history stay. Posting stops. | Reopening needs management. |
| Withdraw message | Tombstone keeps identity and conversation. | No view retrieves the body. |

Moving original content across owners is not reparenting: Share here composes
across owners, an explicit copy makes new resources with recorded source, and
ownership transfer is outside this plan. A reparent can make a subtree grant
lose coverage. The preview discloses it and the operation needs the authority
to change that audience. Previews bind revisions. A changed scope between
preview and commit conflicts.

**Ordering, aggregates, links.** Each conversation has an append order fixed
at commit. Moved messages keep creation markers and source order and get
destination positions at the insertion point. Read state belongs to the
session, keyed by conversation and delivered markers. Branch creation
subscribes only the creator. Search, unread counts, previews, and
notifications use the same scope and history bounds as direct reads and are
invalidated by revocation, withdrawal, and narrowing. A message link restores
a message capability without room membership. Source navigation is separately
authorized. A paused link restores paused access and a revoked one never
restores through a broader publication.

## Operation authority

Rooms declares one typed policy domain. Keys are descriptor entries, never
caller strings, and unknown or unsupported combinations fail before issuance.

| Group | Keys |
| --- | --- |
| Directory participation | `Browse` public listings. `Presence` registers a name and inbox. `Introduce` requests introductions. `Signal` exchanges signaling. Introduce and Signal require Presence. |
| Directory construction | `CreateRoom` creates an independently owned room. `PublishListing` publishes an exact held room reference. |
| Conversation participation | `Receive` live content and roster. `History` retained events. `Post` speaks and types. `EditOwn`, `WithdrawOwn` on lines created through this grant. Post, EditOwn, WithdrawOwn require Receive. |
| Content and files | `ReadContent` selected objects. `ReadFile` bounded readers. `Upload` stages and posts files (requires Post and file storage). |
| Room facilities | `SetTopic` (requires Receive). `Invite` creates offers within held delegable authority. `Moderate` removes live seats and changes no grant. |
| Collection structure | `ListEntries`, `CreateChild`, `Rename`, `Reorganize`, `ArchiveConversation`, `EditContent`, `WithdrawContent`. |
| Session workspace and custody | `ObserveWorkspace`, `InteractWorkspace`, `ReplaceWorkspace`, `ManageCustody`, `ResolvePending`, `UseOperations` (shipped, see the [effect contract](../rooms/session-effects.md)). |
| Archive storage | `RecordArchive`, `ReadArchive`. Returned files also need ReadFile. |
| Resource administration | `ManagePublicOffer`, `ManagePublication`. Neither grants moderation or access control. |

**Keys by resource kind.** Each kind declares the keys it supports in a
`SUPPORTED` list beside its `KIND` constant, as `content/session.rs` does for
the session. A grant on a kind never carries a key outside its row, and a
preset that names an unsupported key is unavailable on that kind.

| Kind | Supported keys |
| --- | --- |
| Directory | Browse, Presence, Introduce, Signal, CreateRoom, PublishListing, ManagePublicOffer |
| Room | Receive, History, Post, EditOwn, WithdrawOwn, ReadContent, ReadFile, Upload, SetTopic, Invite, Moderate, ListEntries, CreateChild, Rename, Reorganize, ArchiveConversation, EditContent, WithdrawContent, ManagePublicOffer, ManagePublication |
| Conversation | Receive, History, Post, EditOwn, WithdrawOwn, ReadContent, ReadFile, Upload, EditContent, WithdrawContent |
| Message | ReadContent, ReadFile, EditContent, WithdrawContent |
| File | ReadFile |
| Archive | ReadArchive, RecordArchive, ReadFile |
| Session | Shipped. `content/session.rs` owns the list. |

Held access control powers (Inspect through DelegateControl below) belong to
the managed control, not to this key domain.

Management is a separate held control enumerating `Inspect`, `Issue`, `Edit`,
`Pause`, `Resume`, `Revoke`, and `DelegateControl` with exact branch scope and
a ceiling for Issue and Edit. History is `None`, `Since(sequence)`, or
`Retained` on the canonical conversation's sequence. Intersection picks the
later boundary, and selecting an old message ID cannot bypass a floor. An
owned subtree includes future children, which the editor says. Linked entries
need their own checks.

**Shared methods.** Use `describe-access`, `derivation-sequence`, `derive`,
`derive-managed`, `durable-name`. Control `describe-control`, `pause`,
`resume`, `revoke`, `mutate`, `mutation-sequence`, `revoke-control`, and
`mutate(... "attenuate-control")`. Observation through `mutate(... "observe")`
with `poll`, `receive`, `cancel`. Owner `sweep`, `retire-owner`,
`maintenance-step`. These exist in the
[managed endpoint guide](../loam/access.md). Rooms adds decoders and
interfaces, and interface generation rejects an undeclared callable method:

| New method | Authority and result |
| --- | --- |
| Control `mutate(sequence, "set-policy" / "set-label" / "set-status", revision, terms)` | Edit, or the matching Pause, Resume, Revoke. Ceiling, source, and generation cannot change. |
| Control `mutate(sequence, "issue-access", revision, request)` | Issue within scope and ceiling. Returns the child use facet and a separately bounded issuer control. |
| Control `inventory(cursor, limit)` | Inspect over the administered branch. At most 32 rows, revision-bound cursor, no bearer secrets. |
| Use or Issue control `mutate(sequence, "issue-offer", revision, request)` | Invite plus current delegation, or Issue within its ceiling. Terms, ceiling, scope, both admission modes, lifetime, label. Returns offer use and offer control separately. |
| Offer `describe-offer`, `claim-offer(sequence, receipt, contract-revision)` | Claim binds the described generation and terms. Result is the accepted grant or one-visit seat, never a control. |
| Offer control `close-offer(sequence, revision)` | Stops new claims. The source grant and accepted children are untouched. |
| Accepted access `join` | Returns one scoped seat and facilities under the current grant. |
| Collection `entries`, `create-child`, `rename`, `move-entry`, `move-conversation`, `move-messages`, `split`, `merge`, `archive-conversation` | ListEntries, CreateChild, Rename, Reorganize on source and destination plus audience-change control, ArchiveConversation. |
| Message `read-content`, `attachments`, `edit-content`, `withdraw-content` | The matching content and file keys. |

Offer terms freeze at creation. Changing them closes the offer and issues a
replacement. Live continuing access rejoins while its host survives.
Persistent continuing access has an exact publication. Persistent one-visit
offers survive until claimed but their seat ends with the runtime. No seat is
restored after restart.

**Methods to replace.** The current grammar in
[the generator](../../tools/gen/rooms_protocol.zig),
[`protocol_operator.ts`](../../apps/rooms/lib/protocol_operator.ts), and
[`protocol_handover.ts`](../../apps/rooms/lib/protocol_handover.ts) maps onto
the keys above as follows. Names may change. Effects and authority may not.

| Current methods | Required authority and result |
| --- | --- |
| Directory `list`, `listPublications`, `watch`, `watchPublications`, `advertisedLocation` | Browse. Public rows only. Watch is scoped observation. |
| Directory `enter`, `enterPublication` | Browse. Returns only the current public offer and its generation. |
| Directory `open`, `openManaged`, `openPrivateLink` | CreateRoom plus parent CreateChild for nesting. Issuer gets explicit ownership and an exact recovery result. |
| Bootstrap `roomAuthorities` | Exact creation receipt, never a lookup by name. |
| Directory or manager `link` | Removed. Replaced by exact held publication or room Issue control. |
| `publishDurableRoom`, lease `ready`, `revoke` | PublishListing plus a held room reference. Lease revocation removes discovery only. |
| `register`, `memberRegistration`, `offerInbox`, name `voucher` | Presence. Vouchers are one-use continuity proofs retired on replacement, pause, or revoke. |
| `introduce`, `requestDirect`, `offerSignaling`, `signal*` | Introduce or Signal plus current registration. Established direct capabilities are independent. |
| Entrance `called`, `private`, `roomPolicy`, `subscribe`. Invitation `mintInvitation`, `claimInvitation` | Replaced by typed offers with four admission modes. Subscribe or join consumes exact accepted access. |
| Seat `membershipKind`, `away`, `leave`, `post*`, `typing`, `history` | Active seat. Post returns the line facet in one reply. History with cursor and floor. Leave is always allowed. |
| Topic `setTopic`, files `attach*`, `postFiles*`, upload `write`, `discard`, file `read`, line `edit`, `withdraw`, `refile` | SetTopic, Upload plus Post, current Upload per chunk, ReadFile plus projection, EditOwn or EditContent, WithdrawOwn or WithdrawContent, Upload for refile. |
| Moderator `governs`, `kick`, manager `setRoomPolicy`, `unregisterRoom` | Moderate (ends a seat only), ManagePublicOffer, and ManagePublication. |
| `giveSteward`, `giveManager`, `revokeSteward`, `revokeRoomLink`, `revokeRoomAuthority` | Replaced by exact Issue and Revoke controls with ceilings. |
| Direct inbox `dm`, `handRoom`, `offerRoom`, `handArchive`, `offerArchive`. Direct line edits | Held direct capability. Direct sharing passes the exact reference, managed sharing derives first. |
| Archive `put*`, `read`, `attachment`, `blob`, `narrow`, `share`, `shares`, `revokeShare` | RecordArchive or ReadArchive and ReadFile. The share ledger is replaced by Issue, Inspect, Revoke controls over exact publications. |
| Room `bridgeForm`, `submitBridgeForm` | Receive plus bridge support. Post plus declared bridge effects. Credentials stay transient. |
| Session `facet`, `revoke`, `issueGrant`, `setGrantPolicy`, `revokeGrant` | Replaced by shared derivation and controls. |
| Operator methods | Separately held operator capability, never on a public root. Session mediation needs UseOperations. |

Roster, seat, line, receipt, topic, typing, listing, registration, policy,
direct, and signaling callbacks are deliveries whose producer rechecks the
originating requirement at delivery. Status channels carry no content while
paused or revoked. Unknown notifications may be skipped. Unknown callable
methods fail closed.

## Access editor

The editor is one interaction for every resource. It separates what access
permits from whether it is active.

| Term | Meaning |
| --- | --- |
| Grant | The issued access as a whole: policy, lifetime, status. |
| Scope | Which resource or bounded content the grant covers. |
| Permission | One allowed action. |
| Policy | Configured permissions and typed constraints. Labels are metadata. |
| Preset | A named, described combination that replaces a declared group of fields. |
| Status | Active, paused, or revoked. |

Presets replace exactly their group's fields (an omitted Boolean becomes
false) and leave other fields alone. Groups own disjoint fields. Every group
has a Custom action that opens the individual controls with current values.
An exact match shows "Matches Observer" without closing the customizer, and
opening or closing it changes nothing. Saving records explicit values, so
changing a preset definition never changes issued access, and a new
permission is absent until an authorized edit adds it within the ceiling. The
owner validates the whole change atomically and explains an unavailable
preset instead of applying a smaller one. Configured and effective access are
shown apart. A parent restriction is explained beside the control. Editing a
paused grant keeps it paused. Revocation cannot be undone by a preset.

| Group | Replaced fields | Presets |
| --- | --- | --- |
| Directory Participation | Browse, Presence, Introduce, Signal | Visitor: Browse. Member: all four. |
| Directory Construction | CreateRoom, PublishListing | None. Creator. Publisher. Builder: both. |
| Participation | Receive, Post, EditOwn, WithdrawOwn | Observer: Receive. Speaker: Receive, Post. Participant: all. |
| Content Reading | ReadContent, ListEntries | Item reader. Collection reader: both. |
| Files | ReadFile, Upload | None. Reader. Contributor: both. |
| Room Facilities | SetTopic, Invite | None. Host: both. |
| Moderation | Moderate | None. Moderator. |
| Collection Structure | CreateChild, Rename, Reorganize, ArchiveConversation | None. Organizer: all four. |
| Exact content editing | EditContent, WithdrawContent | None. Editor. Curator: both. |
| Session Participation and Custody | shipped | see the [session guide](../rooms/session.md) |
| Archive Storage | ReadArchive, RecordArchive | Reader. Recorder. Custodian: both. |
| Public Resource Settings | ManagePublicOffer, ManagePublication | None. Publisher. Manager: both. |
| Held access control | Inspect, Issue, Edit, Pause, Resume, Revoke, DelegateControl | Inspector. Grant manager: all but DelegateControl. Administrator: all. |

A preset listed with no fields covers exactly one field, and single presets
follow the group's field order: in Files, Reader is ReadFile and Contributor
is both. None clears the group. A kind offers a group for the fields it
supports. A preset naming an unsupported field is unavailable there and the
editor says so. The session's two groups are Session Participation and
Custody, so no group name repeats across kinds.

History, floor, scope, source dependency, lifetime, label, ceiling, quotas,
and status stay independent controls. A restricted directory exposes Visitor
only. An Open deployment adds Member and CreateRoom with quotas shown. A
room's Open public offer grants Participant, ReadContent, ReadFile. Moderated
grants Observer, ReadContent, ReadFile. Private publishes no offer. Public
offers are reusable one-visit admissions whose accepted grants the owner
issues under the accepted terms. Rejoin is a new admission.

**Inventory and dialogs.** The Access action opens a paged inventory under the
held control: label, scope, configured and effective access, source
restriction, lifetime, status, offer or grant. Opening a row binds a draft to
generation and base revision. Save sends full values and the operation
identity and shows success only after the owner acknowledges. A conflict keeps
the draft beside the fresh snapshot. An unknown outcome retains the request
and never auto-reissues. Share offers Send existing access and Create managed
access. Copy link copies only the use or offer reference. Create invitation
adds Single or Reusable and One visit or Can rejoin, and the acceptance page
shows the same terms before Accept. Pause, Close invitation, and Revoke branch
are distinct with separate previews naming visible dependents, unknown counts,
and remaining public routes. Confirmation binds the preview revision. Every
dialog has cancel and save, keyboard focus, and focus return. A
self-revocation lands on the terminal status view. Sandstorm's permission
bundles and E's caretaker pattern are the precedents. Explicit saved values
are chosen so a preset edit cannot widen existing shares.

## Storage and budgets

An authority owner has one managed owner header and one transaction boundary
over its content and access state. Nested owned rooms charge the containing
owner's quota. An independent owner needs construction authority and charges
the service's aggregate quota until explicitly destroyed. Managed resources,
grants, controls, endpoints, recipes, directories, change history, and retry
windows use the shared schemas in `src/loam/access/records/`. Whether these
content records subsume the kept-lines history seam is undecided
([ADR-0208](../decisions/adr/ADR-0208-rooms-retention-storage-split.md)).

| Record | Payload and edges | Transaction owner |
| --- | --- | --- |
| Content root | Owner identity, schema version, incarnation marker, index root, quotas. Strong edge to the owner header. | Hosting owner. |
| Collection | Resource and generation, label, kind, archived flag, entry index, default conversation for a room. | Content module. The managed row owns the canonical parent. |
| Conversation | Resource and generation, label, archived flag, next sequence, message index. | Content module. |
| Message | Resource and generation, position, authored context, creation sequence, body state, reply target, bounded file and provenance edges. | Content module. A move changes parent and position only. |
| Placement | Entry ID, destination, order, label, target kind, exact held target edge, disclosed source. | Destination owner, with authorized removal at source. |
| File | Resource and generation, metadata, blob identity and length, retention handle. | File owner. Readers retain grant and projection dependencies. |
| Branch provenance | New and source identities, disclosed context, optional source-view capability. | New conversation owner. |
| Offer | Offer and generation, issuer use dependency, control descriptor, frozen terms and ceiling, both modes, lifetime, next claim sequence, closed flag, bounded claim results. | Admission owner. |
| Admission result | Offer, generation, sequence, receipt digest, intent, result kind, accepted endpoint or seat. | Admission transaction. Replay needs the held offer and exact receipt. |
| Effect receipt | Operation identity, intent, source generation, committed or unresolved outcome, bounded result fields. | Existing effect owner. |

Session custody and effect receipts are shipped
([session guide](../rooms/session.md)). Saved references follow
[ADR-0182](../decisions/adr/ADR-0182-held-authority-reference-recipes.md). A
foreign durable save checks that the sturdyref restores the held capability,
and no fallback saves a parent with a client-side path.

Admission commits the child grant, endpoint, publication when persistent and
continuing, receipt, and claim sequence together before exposing authority.
Single-use offers retain the first winning result. Reusable offers keep a
monotone sequence and the last eight results, refusing changed intent and
future sequences and returning ReceiptExpired for evicted ones. Clients keep
the sequence and a 128-bit receipt before sending. Seats, uploads, typing,
vouchers, and signaling are runtime state that restart ends. Live grants and
offers bind the host-incarnation marker, which a durable owner advances once
before admitting after restart. Exhaustion refuses startup. Unknown writes
fence the owner until recovery. Confirmed commit precedes publication,
notices, and replies.

**Reorganization transaction.** Preview obtains source and destination
capabilities, revisions, and the exact selection, and lists gains and losses
for subtree grants and preserved exact-object grants. A separately held
AudienceChange control (an Issue or Edit control whose scope and ceiling cover
the content and destination) is required when content becomes newly exposed.
Reorganize alone cannot do it. Commit updates containment, indices, positions,
retained fields, and change stamps together within the shared bound of 16
managed effects. Oversized selections refuse before any move. Cross-owner
placement is two acknowledged acts and a failed removal reports two
placements.

**Capacity profile.** Each row is a hosting-owner profile, registered through
shared descriptors and executor budgets.

| Owner profile | Active grants | Open offers | Seats or views | Watches | Pending protected calls | Authority payload |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Directory | 2048 | 128 | 256 registrations | 256 | 8 | 16 MiB |
| Room or content tree | 512 | 128 | 128 seats | 128 | 8 | 4 MiB |
| Session | 64 | 32 | 32 attachments | 32 | 8 | 1 MiB |
| Independently hosted archive | 512 | 64 | 128 readers | 128 | 8 | 4 MiB |

Per grant: at most 32 direct children, depth 16, four concurrent seats, eight
watches. Containment depth 64. Derived branches share the original grant's
reservations. Service-wide: 256 owners, 4096 grants, 512 seats, 256 watches,
eight pending protected calls, 32 MiB authority payload, 256 MiB persistent
authority records. Startup refuses missing limits. Inventory and history pages
are at most 32 rows and 64 KiB. Labels 120 UTF-8 bytes. Status explanations
200 UTF-16 units. 64 signaling exchanges per directory. One shared 64-slot,
64 KiB-per-slot record cache, 4 MiB of record buffers, eight in-flight managed
calls, 64 KiB of arguments per protected call with uploads streamed. Quota
exhaustion refuses issuance and never evicts live grants or reuses terminal
identities. The persistent-byte limit needs operator action, not deleted
revocation evidence.

**Cost evidence.** The Zig
[recorded workloads](../../bench/loam/results.md) support the pressure
populations and cache profile but measure no Rooms admission, browser memory,
sockets, or latency. Before a phase completes, publish for each path:

| Path | Required evidence |
| --- | --- |
| Startup | Lazy owner headers and listeners. No population scan or seat fan-out. Reads, peak heap, backend bytes, first-use cost at full profile. |
| Ordinary message | Resident evaluation allocates nothing. Cold preparation depends on depth and index paths, not grant count. Copies, reads, allocations counted separately. |
| Grant changes | Response follows durable commit. Narrowed powers deny. Paused silence, stale facets, independent progress shown. |
| Branch revocation | One commit fails every dependent admission. Cleanup yields in bounded steps. Reads, writes, heap at maximum fan-out. |
| Return and reconnect | Exact publications restore without broad links. The ninth managed call refuses while unrelated work proceeds. |
| Churn | Offer, claim, revoke cycles release payload and blobs. Terminal identities, reservations, and bytes counted. Refusal at every limit. |

## Consumers to replace

Paths are under `apps/rooms/rust/`. Recovery requires held source or result
authority. An ID, nickname, or failed check cannot select a stronger method.

| Current owner | Replacement |
| --- | --- |
| Private room recovery keys in `application/src/directory/creation.rs`, `application/src/session/checkpoint/commands/results.rs`, `services/src/server/rooms.rs`, `services/src/server/authority/queue/` | Bounded creation receipts with exact ownership results. Delete recovery-by-name and broad link minting. |
| Role generations in `services/src/server/authority.rs`, `services/src/server/document.rs`, `application/src/server/document.rs` | Shared endpoints and controls. Remove publication reconstruction and duplicate revocation ledgers. |
| Live invitation in `application/src/server/invitation.rs`, `services/src/server/invitations.rs`, `glowcap/src/client/invitation.rs` | Four-mode offers and atomic claims. Delete fixed observer or participant and connection-only admission state. |
| Rejoin in `runtime/src/session/managed/results/invitation.rs`, `application/src/session/checkpoint/` | Retain the exact accepted endpoint. No implicit room-link mint. |
| Nickname voucher in `services/src/server/registration.rs`, `application/src/server/directory/registry.rs`, `glowcap/src/client/directory/registration/` | Keep one-use continuity and authenticated comparison (ADR-0142). Add grant and generation checks. Never persist a voucher in a checkpoint. |
| Archive shares in `application/src/archive/shares/`, `runtime/src/archive/publications.rs`, `apps/rooms/lib/archive/durable_protocol.ts` | Managed exact-scope publications. Archive records stay content. |
| Operator state in `services/src/server/capabilities.rs`, `services/src/server/operations/` | Keep the separate operator front. Mediate attachment access with UseOperations. Never expose on a public root. |

## Walkthroughs

Each row is an acceptance scenario, proved on production fronts.

| Scenario | Issue | Use and change | Reconnect and revoke |
| --- | --- | --- | --- |
| Session display | Create managed access "display": Observer, History off, no custody, persistent, with a ceiling allowing later Collaborator. | Sees live state only. Promotion within the ceiling keeps the link. Pause carries no content. A copy is the same grant. | Restores the exact endpoint and cursor. Revocation stops the display and its children while seats and other views continue. |
| Room helper | Single admission, Can rejoin, Speaker, History off, no Upload, SetTopic, Invite. | Join returns a seat. Files, topic, and minting refuse. Promotion needs ceiling and source. Narrowing makes retained facets refuse at the next effect. | Rejoins through the exact grant, never a room link. Receipt retry returns the same result. Close keeps access, Revoke branch ends it, Kick ends a seat only. |
| Directory visitor and creator | Member access plus a separately controlled CreateRoom grant. | Registration returns a dependent voucher. Creation records an independent room with explicit ownership. Listings grant nothing. | Narrowing to Visitor releases presence, inbox, introductions, signaling. Revoking CreateRoom stops creation without destroying rooms. |
| Existing session authority and a managed equivalent | Send existing access hands the exact capability. Create managed access issues equal terms with a source dependency. | Both exercise their operations. Only the managed grant has a control, ceiling, revision, and pause. | Each saves its own form. Revoking the child keeps the original, revoking the source disables the branch, revoking only the control keeps use. |
| One message from a nested room | An exact message scope with ReadContent and permitted projections. | Focused view, placement elsewhere, Reply in source needs posting authority. Narrowing stops readers, previews, search, notifications. | Saved with a checked sturdyref. Restoration never walks a room root. Revoking the reshare leaves an unavailable entry. |

Reorganization: rename keeps everything. Same-owner move, split, and merge
preview selection, revisions, coverage changes, and preserved grants, need
AudienceChange when content is newly exposed, and commit atomically within
16 effects. Cross-owner placement is insert then remove, reporting two
placements on partial failure. Every proof holds older topic, file, line, and
name references across a change, loses an acknowledgement at the authority
commit, reconnects with exact retained terms, and keeps an independent
capability usable on the same connection.

## Ordered implementation and exit criteria

Phases 1 and 2 (the common lifecycle and the managed session) are complete.
Each remaining phase replaces unreleased contracts at their owners, deletes
the replaced code and fixtures in the same slice, and updates generated
metadata, clients, protocol docs, shipped inventory, and known limitations.

3. **Recursive rooms and scoped content.** Exit: a helper can speak without
   inviting, loses file and topic powers on retained references, pauses,
   resumes, and reconnects under the same grant. Branch revocation survives
   restart. A shared message survives restoration without exposing siblings.
   Cross-owner mediation preserves refusal. The steps alternate seams and
   sweeps. A seam opens a mechanism nobody has read yet and stays with a
   capable planner. A sweep applies a settled rule to counted sites. A cheaper
   executor can run it once the seam before it has landed and its contract
   cites files and lines.
   - **3a seam, one policy catalog.** Move `Group` and `Preset` out of
     `content/session.rs` into a Rooms-wide catalog over `Permission`, make
     `Terms` generic over a kind marker that carries `KIND` and `SUPPORTED`,
     filter groups and presets per kind by the rule above, and make the
     browser metadata generator and the declaration proofs iterate the kinds.
     `apps/rooms/test/commands_test.ts` reads the session group keys by name.
   - **3b sweep, declare the kinds.** One module per row of "Keys by resource
     kind" and one catalog row per preset in the editor table, with labels
     and one-sentence descriptions in the voice of the session presets, then
     regenerate the mirror. Gate: `rooms-rust-test` and
     `rooms-browser-metadata-check`.
   - **3c seam, room-owned grants on Loam.** Offers, admission receipts,
     continuing memberships, dependent facets, manager and moderator
     boundaries, persistent limited offers, exact reconnection custody. The
     records in "Storage and budgets" and the new methods in "Operation
     authority".
   - **3d sweep, replace the methods.** One batch per row of "Methods to
     replace": route callers to the new method and delete the old one with
     its generator grammar, clients, and fixtures. Gate:
     `gen-rooms-protocol-check`, `rooms-server-test`, `rooms-peers-test`,
     `rooms-terminal-client-test`.
   - **3e seam, content on managed containment.** Collections, conversations,
     messages, placements, branch provenance, and the reorganization
     transaction with retained source context.
   - **3f sweep, replace the consumers.** One batch per row of "Consumers to
     replace", deleting the replaced owner in the same batch.
   - **3g seam, the editor over every kind.** Room access inventory, item
     sharing, member-to-grant inspection, invitation choice and acceptance,
     and desktop client support, on the kind-generic `PermissionFields`.
   - **3h sweep, walkthroughs as proofs.** One batch per walkthrough row,
     each reviewed cold on the planner tier before it counts as evidence.
4. **Directory access.** Split the public offer from use and management
   facets. Cover every directory verb and registration or signaling path.
   Ship the directory editor and bootstrap configuration with clients and
   operating docs. Remove the unrestricted bootstrap. Exit: creator access
   revokes while browsing continues under another grant, created rooms stay
   owned, and an independently authorized room or DM on the same transport
   continues through directory grant retirement.
5. **Conversation workflows and outside-peer evidence.** Exercise all owners
   together, peered rooms, local and durable sessions, multiple views, every
   shipped client, both IRC edges. An interactive conversation view with
   scoped history, unread, search, notifications, and rename, split, merge,
   move under the audience contract. A sharing scenario that visibly issues,
   narrows, passes, and revokes authority on production fronts. Depends on the
   two Loam residuals named above.
6. **Audit and retire.** Check the composed product for overlooked recovery
   paths, duplicated policy, and stale assumptions. Reconcile shipped
   inventory, boundaries, protocol pages, operating guidance, and ADR links.
   Delete this plan when every row below has evidence or is explicitly
   removed from scope.

### Verification matrix

| Scenario | Evidence required |
| --- | --- |
| Allowed and denied operations | Every operation succeeds with its authority and is refused without it, through desktop and browser clients. |
| No public bypass | Refetching bootstrap, old entrances, or alternate verbs cannot recover withheld powers. Intentionally public access remains. |
| Exact scope | Foreign IDs, old generations, sibling grants, reused names, stale dialogs, forged view records confer nothing. |
| Delegation | Copies share revocation. Children attenuate. A parent's restriction constrains its children, and its expansion cannot exceed a child's ceiling. Independent grants survive. |
| Offer admission | Concurrent claims, repeated receipts, cancelled waits, crashes, lost replies produce exactly the recorded admission. One-visit and rejoin differ as advertised. |
| Live changes | Held topic, file, upload, line, history, naming, watch references obey current rights. Promoted holders acquire new facets. |
| Change observation | Committed edits emit scoped events over CapTP. Failed edits emit none. Reconnect and overflow resynchronize. Missed events never preserve permission. |
| Pending effects | Revocation during storage, handoff, upload, introduction, signaling, or watch delivery prevents a later effect or disclosure. |
| Isolation | Revoking one grant does not close transport or retire unrelated memberships. |
| Persistence | Revoked branches stay dead. Edits preserve links. Uncertain writes fail closed. Receipts recover. Corrupt stores do not remint. |
| Resource pressure | Every limit refuses safely. Churn cannot bypass aggregates. Message admission stays within measured cost. |
| Editor | Preset replacement, Custom mode, lifecycle independence, stable issued policy. Scoped inventory, stale revisions, self-revocation, keyboard, narrow layouts. |
| Content | First use, message identity, branch, private branch, shared reply, reorganization, cross-owner placement, deep link, aggregates, continuity. |
| External consumers | Goblins and shipped language and IRC clients observe both permitted and refused behavior on baseline CapTP. |

Deterministic policy tests live in `rooms-application`. Contract fixtures
replay through `rooms-contract-proofs` in Rust and Wasm. Storage and live
ownership in service and platform tests. Browser custody through the real
exports. UI through page proofs. Validate new checks against injected
defects, including stale cached rights and a bootstrap bypass. Focused steps:
`zig build rooms-rust-test`, `rooms-rust-browser-test`, `rooms-server-test`,
`rooms-peers-test`, `rooms-terminal-client-test`,
`gen-rooms-protocol-check`, `rooms-browser-metadata-check`,
`rooms-web-proofs`, `goblins-rooms`, `goblins-rooms-irc`. A phase ends with
`zig build check`, `runtime-check`, and `check-external`.

Completion means recursive resources support deliberate direct sharing and
separately managed facets without accidental authority. UI and non-UI callers
exercise it. Persistent grants and receipts recover. Limited access stays
limited through every returned capability and reconnection, and the matrix has
recorded results on the implementation commit. The constraints to turn into
typed seams and scenarios: presence is not admission authority. Matching UI
controls do not imply matching enforcement. Copying creates no grant. Facets
retain origin and can be durable. Placement is not an authority parent.
