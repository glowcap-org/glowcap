# Rooms operation authority

Status: active plan. This is the phase 1 operation contract for the
[Rooms integration plan](access-grants.md). It specifies implementation requirements,
not shipped wire methods. The [sharing decision](../../decisions/adr/ADR-0183-rooms-scoped-sharing-and-recovery.md)
owns the change to session grants and room admissions.

## Policy declarations

Rooms declares one typed policy domain over its content resources. These names
identify permission keys in that descriptor, not strings supplied by a caller.
Each key is independent unless the table states a validation requirement.
Resource interfaces admit only applicable keys. Unknown keys and unsupported
combinations fail before issuance or editing.

| Group | Keys and meaning |
| --- | --- |
| Directory participation | `Browse` reads public listings and location; `Presence` registers a name and offers an inbox; `Introduce` requests direct introductions; `Signal` exchanges signaling. Introduce and Signal require Presence. |
| Directory construction | `CreateRoom` creates an independently owned room; `PublishListing` publishes an exact held room reference. Neither implies the other. |
| Conversation participation | `Receive` subscribes to live content and roster; `History` reads retained conversation events; `Post` speaks and types; `EditOwn` edits a line created through this grant; `WithdrawOwn` withdraws it. Post, EditOwn and WithdrawOwn require Receive. |
| Content and files | `ReadContent` reads selected messages or objects; `ReadFile` obtains bounded file readers; `Upload` stages and posts files. Upload requires Post and an owner that supports file storage. |
| Room facilities | `SetTopic` changes the topic; `Invite` creates offers bounded by held delegable authority; `Moderate` removes live memberships in its declared scope. SetTopic requires Receive. Moderate cannot change a grant. |
| Collection structure | `ListEntries` reads scoped placements; `CreateChild` creates a conversation or nested collection; `Rename` changes a label; `Reorganize` changes membership or placement; `ArchiveConversation` stops posting; `EditContent` and `WithdrawContent` modify exact content through explicitly issued authority. |
| Session workspace | `ObserveWorkspace` reads live session state; `InteractWorkspace` changes ordinary intent and requests effects. InteractWorkspace requires ObserveWorkspace. Every effect also requires the session's held target authority. |
| Session custody | `ReplaceWorkspace` replaces the checkpoint; `ManageCustody` imports, removes or replaces retained authorities; `ResolvePending` decides an unresolved effect; `UseOperations` invokes retained operator capabilities. These keys require ObserveWorkspace. |
| Archive storage | `RecordArchive` writes records and attachments; `ReadArchive` reads selected records. Returned files also require ReadFile. Recording does not grant reading or administration. |
| Resource administration | `ManagePublicOffer` changes public admission; `ManagePublication` removes or replaces discovery leases. Neither grants moderation or access control. |

Management is a separate held control. Its descriptor enumerates `Inspect`,
`Issue`, `Edit`, `Pause`, `Resume`, `Revoke`, and `DelegateControl`, with exact
grant/branch scope and a policy ceiling for Issue and Edit. They are not a
single administration bit on a use facet. Read-only inventory control has
Inspect alone. Moderation can end a seat without revoking permission to return.
An action that does both must obtain and exercise both authorities explicitly.

History has a typed constraint: `None`, `Since(sequence)`, or `Retained`.
Sequence belongs to the canonical conversation and its generation, not a
sender clock. None requires History off. Since and Retained require History on;
intersection selects the later boundary. Reconnect preserves a continuing
grant's boundary. Receive without History starts at each new seat's admission
and supplies no missed-message replay. A selected old message requires source
authority covering that message; selecting an ID cannot bypass a history floor.

Scopes are exact object, bounded object set, owned subtree, or declared
projection, as specified by the [shared API](../loam/access/api.md#scope-and-policy).
The editor discloses that an owned subtree includes future children. Linked
entries retain capabilities and require their own checks; they do not extend a
subtree. An exact-message share exposes only that message and its permitted
attachment projections.

## Common use and control methods

The shared method names below come from the [managed endpoint guide](../../loam/access.md).
Rooms extends their application decoders rather than defining another lifecycle
registry. The rows marked new describe required application or shared-interface
extensions. Interface generation must reject an undeclared callable method.

| Object and method | Authority and result | Retirement owner |
| --- | --- | --- |
| Use `describe-access` | Current scoped access/status; no ancestor inventory or bearer secret. | Managed access bounds observation and stops content disclosure when unavailable. |
| Use `derivation-sequence`, `derive`, `derive-managed` | Current source scope, terms and delegation bounds; same-content child use, and separate issuer control for managed derivation. | Shared source dependency and receipt window govern both publication and recovery. |
| Use `durable-name` | Exact published endpoint only; never its root, control or another role. | Publication owner retains that endpoint and its dependency. |
| Control `describe-control` | Its own current management terms/status. | Shared control dependency. |
| Control `pause`, `resume`, `revoke`, `mutate`, `mutation-sequence` | Matching explicit control power; mutate sequence binds decoded exact intent and original result. | Shared grant/control lifecycle and bounded receipts. |
| Control `mutate(sequence, "set-policy", revision, terms)`, `"set-label"`, `"set-status"` (new decoders) | Edit for policy/label, or matching Pause/Resume/Revoke for status. All carry expected revision; ceiling/source/generation cannot change. | Shared transaction and source dependency. |
| Control `mutate(sequence, "issue-access", revision, request)` (new decoder) | Issue, scoped target and management ceiling; returns exact child use and separately bounded issuer control. Request declares scope, terms, ceiling, delegation, lifetime, label and initial status. | Shared transaction, source dependency and exact receipt recovery. |
| Control `inventory(cursor, limit)` (new interface) | Inspect over exact administered branch; cursor binds revision, scope and generation. Maximum 32 rows; no bearer secrets. | Owner retires cursor work on control loss; stale revision requires refresh. |
| Use/control `mutate(sequence, "observe")`; receiver `poll`, `receive`; canceller `cancel` | Exact descriptor observation and independent cancellation, as specified by the shared profile. Paused/terminal replies disclose status alone. | Shared observation context owns leases, sealed cursor, names and queued work. |
| Control `revoke-control`, `mutate(sequence, "attenuate-control", ...)` | Self-retirement or equal/narrower powers and ceiling; creating another administrable control additionally needs DelegateControl. | Shared control ancestry; retiring control does not retire independent use. |
| Owner `sweep`, `retire-owner`, `maintenance-step` | Separately held hosting-owner capability and exact maintenance sequence. Ordinary use/control cannot produce it. | Shared bounded maintenance fences ordinary calls and retires owned records/publications. |
| Offer `describe-offer`, `claim-offer(sequence, receipt, contract-revision)` (new) | Held offer describes exact terms and claims with an unguessable receipt. Result is the exact accepted grant or one-visit seat; no management capability. | Application offer state and shared source grant; accepted children have separate edges. |
| Offer control `close-offer(sequence, revision)` (new) | Separately held exact offer control stops new claims at its expected revision. It does not revoke the source grant. | Admission owner and bounded receipt; accepted children retain their own dependencies. |
| Accepted access `join` (new) | Exact active continuing grant; returns one scoped seat and facilities. One-visit offers instead return the single admitted seat. | Room admission transaction and live seat owner. |

Single-use/reusable and one-visit/continuing are independent choices. All four
combinations are supported. Live continuing access can rejoin while its host
and retained reference survive. Persistent continuing access also has an exact
publication; persistent one-visit offers survive until claim, but their admitted
seat ends with its runtime. No seat is restored after restart. Expiry is absent.
Closing an offer stops further admissions; revoking its source branch also
stops admitted children. An offer cannot return a public entrance as its result.
Offer terms are frozen at creation. Changing the offer closes it and explicitly
issues a replacement; accepted grants remain separately editable through their
controls. Acceptance binds the described offer generation and terms, refusing
a stale or substituted contract before recording a claim.
Offer issuance is `mutate(sequence, "issue-offer", revision, request)` on an
authorized room use or Issue control. The request includes offered terms,
ceiling, source scope, delegation, both admission choices, lifetime and label.
The result separates offer use and offer control. A use caller additionally
needs Invite and current source delegation; an Issue control stays within its
explicit management ceiling and source dependency. A recipient cannot acquire
offer control by describing or claiming the offer.

## Existing methods and their replacement requirements

These rows inventory the current grammar in
[the generator](../../../tools/gen/rooms_protocol.zig), the
[operator contract](../../../apps/rooms/lib/protocol_operator.ts), and the
[handover contract](../../../apps/rooms/lib/protocol_handover.ts).
Names can change during implementation; their effects and authority cannot be
omitted. Notifications listed afterward are deliveries, not additional powers.

| Surface and current methods | Required authority and returned capabilities | Retirement owner |
| --- | --- | --- |
| Directory `list`, `listPublications`, `watch`, `watchPublications`, `advertisedLocation` | Browse; only public rows in permitted scope. Watch returns scoped observation, not room authority. | Directory grant owns watch and queued deliveries. |
| Directory `enter`, `enterPublication` | Browse; returns only the exact currently public offer and its policy generation. | Directory discovery dependency and room public-offer owner. Admission must still succeed there. |
| Directory `open`, `openManaged`, `openPrivateLink` | CreateRoom plus parent CreateChild for nested creation; issuer receives explicit new-room ownership and exact recovery result. | Creation receipt retains result; independently created room survives creation-grant withdrawal. |
| Bootstrap `roomAuthorities` | Exact creation receipt capability; returns only the ownership roles committed for that creation. | Room owner and bounded creation recovery, never lookup by name. |
| Directory/manager `link` | No unrestricted lookup by room name. Replace with exact held offer/access publication or explicit room Issue control. | Exact publication owner. |
| Directory peering `publishDurableRoom`; lease `ready`, `revoke` | PublishListing plus actual held room reference; exact lease control. | Directory grant and source-session lease; revoking lease removes discovery, not room authority. |
| Directory `register`, `memberRegistration`, `offerInbox` | Presence; memberRegistration discloses only authorized presence, never a private inbox. | Exact grant and registration generation own name, inbox custody and replacement. |
| Name `voucher` | Held name facet with active Presence dependency; one-use continuity proof. | Registration owner retires vouchers on replacement, pause or revoke. |
| Directory `introduce`, `requestDirect` | Introduce plus current registration; target must consent to disclose its inbox. | Directory owns pending request; accepted direct capability is explicitly independent. |
| Directory `offerSignaling`, `signalOffer`, `signalAnswer`, `signalCandidate`, `signalDone` | Signal plus current registration and exact exchange token; target participates under its own grant. | Directory retires pending exchange and queued candidates; established peer capabilities are independent. |
| Entrance `called`, `private`, `roomPolicy` | Held scoped offer/access describes only its own resource and features. | Room/offer dependency; metadata cannot reveal an inaccessible parent. |
| Entrance `subscribe`, invitation `mintInvitation`, `claimInvitation` | Replace fixed kinds with typed terms and four admission modes; Invite bounds offered terms, subscribe/join consumes exact accepted access. | Offer receipt, accepted grant and seat owners have separate retirement. |
| Seat `membershipKind`, `away`, `leave` | Active seat; membershipKind becomes current access description. Away requires Receive; leave is always allowed to release own seat. | Exact live seat; leaving continuing access does not revoke its grant. |
| Seat `post`, `postWithPreviews`, `postRetained`, `typing` | Post; preview selection is data, with no fetch of unauthorized content. Post returns `[notification ID, dependent exact-line facet]` in one reply. | Seat owns pending post/typing; originating grant governs the returned line. One-visit grants end with their seat. |
| Seat `history` | History and bound cursor/floor. Each returned file requires ReadFile. | Grant and history reader own delivery and derived files. |
| Topic `setTopic` | SetTopic on the current grant, including calls on an older facet. | Grant and exact seat. |
| Files `attach`, `attachRetained`, `postFiles`, `postFilesWithPreviews`, `postFilesRetained` | Upload and Post; returns staged upload/line facets. Retained variants preserve the same requirements. | Grant and seat cancel uploads, release staged blobs and retire pending commits. |
| Upload `write`, `discard`; file `read` | Write requires the current Upload grant; discard releases own staging even when unavailable. Read requires ReadFile plus exact projection. | Upload/file behavior checks origin grant at each chunk and after waits. |
| Line `edit`, `withdraw`, `refile` | EditOwn/WithdrawOwn and creation through this grant, or explicit EditContent/WithdrawContent for that exact line. Refile additionally requires Upload for new files. | Exact line facet retains original grant dependency; withdrawal tombstones source content. |
| Moderator `governs`, `kick` | Moderate over exact room/seat scope. Governs is identity data. | Moderator grant; kick retires a seat only. |
| Manager `managedRoomIdentity`, `setRoomPolicy`, `unregisterRoom` | ManagePublicOffer for policy; ManagePublication for discovery withdrawal. Destruction is a separate explicit owner act. | Room owner commits offer generation and discovery lease retirement. |
| Manager/operator `giveSteward`, `giveManager`, `revokeSteward`, `revokeRoomLink`, `revokeRoomAuthority` | Replace role rotation with exact Issue/Revoke controls and management ceilings. Delayed targets include exact generation. | Shared grant/control/publication owners. |
| Direct inbox `dm`, `handRoom`, `offerRoom`, `handArchive`, `offerArchive` | Actual held direct capability; direct sharing passes exact held reference or checked sturdyref. Managed sharing explicitly derives first. | Receiver owns custody; sender grant still governs any dependent reference. Copied text is data. |
| Direct line `edit`, `withdraw`, `refile` | Exact held line authority; dependent session handoffs keep attachment restrictions. | Direct producer and any mediating grant. |
| Archive `put`, `putFiles` | RecordArchive and scoped coordinate; writing a record is not proof its claimed author is authentic. | Archive writer/owner and staged blob custody. |
| Archive `read`, `attachment`, `blob`, `narrow` | ReadArchive with history/selection bounds; ReadFile for bytes. Narrow returns equal or smaller dependent authority. | Archive grant and returned reader/facet. |
| Archive `share`, `shares`, `revokeShare` | Replace local share ledger with Issue/Inspect/Revoke controls and exact published facets. | Shared managed lifecycle; archive content remains independent. |
| Room `bridgeForm`, `submitBridgeForm` | Form inspection requires Receive and explicit bridge support; submission requires Post plus declared bridge effects. Credentials stay in bounded transient custody. | Room seat/bridge effect owner; no grant serialization of bridge secrets. |
| Operator `snapshot`, `list`, `up`, `down`, `operatorSnapshot`, `operatorRetireMatching`, `watch`, `unwatch`, `revokeNick`, `disconnectSession`, `removeOperatorRoom`, `releaseOperatorReference`, `clearOperatorTrouble`, `resetOperatorScope` | Separately held operator/listener capability. Session mediation additionally requires UseOperations and scoped custody. These never appear on a public directory root. | Existing operator owner; exact scope/generation, scoped worker cancellation. |

## Session methods and command envelope

The compiled [session declarations](../../../apps/rooms/rust/application/src/content/session/requirements.rs)
map every method and typed command to workspace permissions and exact held
target requirements. Conditional requirements distinguish authority imports,
file returns and new uploads. The generated browser metadata is a read-only
mirror; the [integration queue](integration.md#shared-prerequisite-and-remaining-order)
owns its adoption by the dispatcher. These declarations perform no generic
policy evaluation and do not map the new keys to the legacy tiers.

The [facet dispatcher](../../../apps/rooms/rust/runtime/src/session/managed/content.rs) and
[method catalog](../../../apps/rooms/rust/application/src/session/verbs.rs) own
the current surface. InteractWorkspace admits the envelope, not every nested
command. The target capability must authorize each resulting effect.

| Current methods | Required authority and result | Retirement owner |
| --- | --- | --- |
| `snapshot`, `watch` | ObserveWorkspace; scoped live state, with history/files separately checked. Paused views get status only. | Attachment grant and subscription delivery. |
| `command`, `typing`, `sendFiles`, `refileLine`, `roomBridgeForm` | InteractWorkspace plus the command/target requirements below; ObserveWorkspace alone for supported form inspection. | Attachment and target grant; pending effects recheck before dispatch and commit. |
| `readHistory`, `readHistoryView`, `archivedAttachment`, `readArchiveShare` | History/ReadArchive and ReadFile as applicable, intersected with exact held archive scope. | Mediated reader retains attachment and upstream archive dependencies. |
| `adoptWorkspace`, `replaceCheckpoint` | ReplaceWorkspace; importing bearer authority also requires ManageCustody. | Session transaction and exact retained capability fields. |
| `resolveEffect`, `resumeEffect` | ResolvePending and original target requirement; resumption must not duplicate an uncertain effect. | Session effect receipt/recovery owner. |
| `operationsSnapshot`, `operatorSnapshot`, `operatorPage`, `operatorRetire` | UseOperations plus held scoped operator reference. | Session mediator and operator owner. |
| `shareArchive`, `offerDurableArchive`, `listArchiveShares`, `revokeArchiveShare` | Archive Issue/Inspect/Revoke control plus session InteractWorkspace; sharing through attachment creates dependent authority unless independent handoff is expressly authorized. | Archive grant/publication and attachment mediation. |
| `dropArchiveShare` | InteractWorkspace to release local custody; does not revoke another holder's publication. | Session custody owner. |
| `facet`, `revoke`, `issueGrant`, `setGrantPolicy`, `revokeGrant` | Replace with shared exact derivation and controls; use link never supplies control recovery. | Shared managed lifecycle and receipt windows. |

These names are exhaustive over the current typed command enums in
[checkpoint commands](../../../apps/rooms/rust/application/src/session/checkpoint/commands.rs),
[result commands](../../../apps/rooms/rust/application/src/session/checkpoint/commands/results.rs),
and [effects](../../../apps/rooms/rust/application/src/session/command.rs).

| Nested command names | Additional admission |
| --- | --- |
| `setDraft`, `select`, `setStanding`, `setDirectoryStanding`, `setRoomStanding`, `setEffectiveStanding`, `setIgnoredNames`, `setIgnoredName`, `chooseHistoryRetention`, `chooseConnection` | InteractWorkspace; retention cannot expand source history rights, and local ignore is a presentation preference. |
| `joinDirectory`, `leaveDirectory`, `setDirectoryNick`, `joinRoom`, `startDirect`, `openDirect`, `leaveConversation`, `closeDirect` | InteractWorkspace and exact retained directory/admission/direct authority; leaving may always release custody. |
| `acceptInvitation`, `dismissInvitation`, `receiveRoomLinkInvitation` | InteractWorkspace; acceptance consumes exact offered terms and stores exact admitted authority. Receiving a bearer requires ManageCustody if it imports authority outside already authorized intent. |
| `publishPeeredRoom`, `revokePeeredRoom` | PublishListing/exact lease control plus InteractWorkspace; directory revocation never destroys the room. |
| `replaceOperationsCapabilities`, `replaceOperationsBundle`, `selectArchive`, `dropRoomModerator`, `dropRoomManager` | ManageCustody; dropping one's own retained role is not grant revocation. |
| `submitRoomBridgeForm` | InteractWorkspace and room Post plus explicit bridge requirement. |
| `takeRoomLink`, `ensureRoomLink`, `linkRoom`, `takeRoomModerator`, `takeRoomManager`, `recoverRoomManager`, `openManagedRoom` | ManageCustody for role imports, CreateRoom for creation, and actual source control for new authority. Recovery restores exact saved role, never obtains a stronger role by room name. linkRoom is currently a plan-builder operation, not a dispatched command. |
| `offerRoom`, `setRoomTopic`, `kickRoomMember`, `say`, `editLine`, `withdrawLine`, `revokeManagedRoomAuthority`, `unregisterManagedRoom`, `setManagedRoomPolicy`, `operator`, `operations` | InteractWorkspace plus, respectively, exact sharing authority, SetTopic, Moderate, Post, EditOwn/EditContent, WithdrawOwn/WithdrawContent, Revoke control, ManagePublication, ManagePublicOffer, or UseOperations. |
| `setRoomAway`, `retireRoomMembership` | InteractWorkspace and exact held RoomSeat; away requires upstream Receive, and retirement checks the expected seat slot/generation. Retirement clears local seat aliases with the original-target receipt; local conversation removal requires no upstream dispatch. |

## Recursive content and deliveries

New collection methods have explicit names: `entries` needs ListEntries;
`create-child` needs CreateChild; `rename` needs Rename; `move-entry`,
`move-conversation`, `move-messages`, `split`, and `merge` need Reorganize on the
source and destination and the audience-change authorization defined in the
[content contract](content.md#reorganization-contracts). `archive-conversation` needs
ArchiveConversation. Message `read-content`, `attachments`, `edit-content`, and
`withdraw-content` need their corresponding content/file powers. Returned
entries preserve exact saved authority only through an explicitly declared
direct disclosure; ordinary scoped browsing returns dependent views.

Roster, joins, seat changes, line/edit/withdraw/refile events, receipts, topic,
typing, carries, listed/unlisted/opened/closed/count, registration and policy
changes, direct requests/readiness, and signaling callbacks are deliveries.
Their producer rechecks the originating operation's requirements at delivery.
The generated notification names include `notify`, `edited`, `withdrawn`,
`refiled`, `line-bytes`, `directReady`, `directRequested`, `membershipEnded`,
`roomAuthorityChanged`, `roomPolicyChanged`, `registered`, `unregistered`,
`truncated`, and signaling `offer`, `accepted`, `answer`, `candidate`, and `reject`.
History, search, unread summaries, notifications, previews, exports and caches
apply the same scope and history boundary before disclosure. A cache retains
its authority provenance and invalidates disclosure on loss of that authority.
Status channels carry no content while paused or revoked. Unknown notification
extensions may be skipped as data; unknown callable methods fail closed.

The [integration inventory](integration.md) identifies consumers and recovery
routes. Each wire-changing slice must compare its generated callable-method
catalog and typed command variants with this matrix and supply a requirement,
returned-capability declaration and retirement proof for each entry. A method
without those declarations cannot be served through managed access.
