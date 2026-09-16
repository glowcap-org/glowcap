# Access grants across Rooms

Status: active plan. The access module's resource, policy, and local grant core is implemented.
Rooms integration and replacement of its existing grant machinery have not
started. The
[roadmap](../../roadmap.md#durable-applications) owns its priority. This plan covers
application authority and its user experience across recursively composed
Rooms resources and content. It serves the [vision](../../vision.md) through operations for
delegation, attenuation, and revocation on every supported application front.

## The result

Design the complete authority model and product interaction together, before
splitting implementation into phases. Existing code is an inventory of what
can serve that design and what must be replaced; it does not constrain the
public contract. Rooms is unreleased. This work carries no obligation to
preserve its current APIs, wire methods, policy tiers, or stored formats.

A person administering a resource can see the access they have issued, change
what a particular grant permits, pause it, and revoke it. A recipient can see
what their held grant permits and whether that access will survive reconnect
or restart. These operations have the same interaction pattern across Rooms,
while the powers themselves belong to the resource being administered.

The [resource model](resource-model.md) owns recursive composition,
direct sharing of existing authority, separately managed facets, provenance,
and durability. Both sharing modes apply wherever the resource supports them.
The lifecycle below governs managed grants; direct reference sharing creates
no additional grant or recipient-specific revocation control.

The [content plan](content.md) defines conversations, branching, message
membership, reorganization, deep links, and the directory/room/conversation UX.
The [managed access API sketch](../loam/access/api.md) describes typed resource and policy definitions,
real sharing and invocation flows, persistence, and native/foreign interfaces.
The [access architecture](../loam/access/architecture.md) specifies Zig managed access within Loam,
with Rust bindings and actor integration through the existing Host.

These examples define the first complete implementation:

- Give a display access to a session, with live observation but no interaction
  or earlier history. Change that grant without changing its link.
- Invite a helper into a room with permission to speak, but no permission to
  issue invitations, upload files, or change the topic. Promote, narrow, pause,
  or revoke that access while the helper remains connected.
- Give a directory visitor permission to browse and register presence. Give a
  separate grant permission to create rooms. Withdrawing the second grant
  stops new creation without destroying independently owned rooms.
- Pass existing session authority unchanged, or issue an equally powerful
  managed facet whose access can later be withdrawn independently.
- Share one message from a nested room through a durable facet. Place it in
  another room while preserving its source and limits; revoke a derived share
  without revoking independently held access to the original message.

This is Rooms behavior carried by OCapN capabilities. OCapN does not define
Rooms roles, grant ledgers, invitation policies, or account permissions. No new
CapTP message, codec rule, identity registry, or transport privilege is required
by this design. The implementation must demonstrate that with the existing
protocol and outside-peer checks.

## Ownership and authority

### Each resource owns its grants

A directory owns access to discovery, naming, publication, creation, and its
introduction service. A room owns admission and the acts of its memberships.
A session owns attachment to its workspace and the acts that an attached view
may request. The peer hosting each resource enforces its grants.

A directory may list a room on another peer. Listing that room does not make
the directory the room's owner. Grant IDs, resource IDs, nicknames, registration
IDs, labels, and UI rows are comparison or presentation data. Possession of a
live capability or an explicitly retained sturdyref supplies authority.

The default relationship between resources is independent authority. Revoking
directory access stops directory operations and dependent directory services;
it does not revoke independently issued room grants or direct-conversation
capabilities. Revoking a session attachment stops that view's access through
the session; it does not revoke the session owner's room membership.

Dependencies between resources are explicit, as defined in the
[resource model](resource-model.md#dependency-and-durable-ownership).
Local grant records can scope authority to subresources; cross-owner mediation
must retain the actual upstream capability and its restrictions. No shared
process, directory name, checkpoint nesting, or UI containment supplies a
dependency. Partitioned owners cannot acknowledge an uncommitted remote change.

### Distinguish the objects

| Object | Meaning | Lifetime and control |
| --- | --- | --- |
| Resource | An addressable collection, session, or content object with a stable identity and typed operations. | Owned by its hosting application; destruction is an explicit resource operation. |
| Access grant | A bounded record backing one independently managed grant of authority. | Live or persistent as declared; policy can change, suspension is reversible, revocation is terminal. |
| Use facet | The actual capability through which a recipient exercises granted powers. | Every act is checked against the current backing grant and any deliberate parent dependency. |
| Grant control | A capability to inspect or administer a particular grant or bounded branch. | Separate from ordinary use; it cannot name arbitrary sibling grants into its authority. |
| Resource access administration | Authority to issue and administer grants for that resource. | Explicitly granted; a resource's visibility or a member's nickname never supplies it. |
| Invitation | An offer to admit a recipient under specified authority. | Single-admission or reusable, with its own issue, claim, and retirement state. |
| Live membership or attachment | One active use of admitted authority. | Ends on leave or runtime loss without necessarily revoking permission to return. |

Inviting somebody creates access for a new membership. Passing one's own seat
capability delegates the existing seat. Attaching to another person's session
exercises that session's memberships. The UI and protocol must preserve all
three meanings; sharing a session cannot serve as the implementation of an
ordinary room invitation.

### Grant records and policy

Define one typed grant lifecycle across the supported resource types. Its contract
comes from authority, delegation, and failure semantics, independently of the
current session ledger. Reuse existing implementation only where it directly
implements that contract; replace it where it imposes the wrong shape.
A record identifies its owning resource and generation, grant ID, optional
parent authority, target scope, issuance ceiling, current policy, revision, lifetime, status, and
bounded presentation label. Admission receipts and accepted-grant references
belong to the same owner's authority state, not a recipient's checkpoint.

Applications supply typed permission declarations, constraints, operation
requirements, and committed content facts. Managed access owns validation, attenuation,
and effective-rights calculation over those declarations. Avoid both per-resource copied ledgers and a universal permission map of strings
that loses compile-time distinctions between a directory and a room.

The issuance ceiling bounds later policy edits. Resource administrators can
intentionally issue a grant whose ceiling allows later promotion. A recipient
creating a child grant can set its ceiling no higher than the authority it
currently holds and may delegate. Later expansion
of the parent cannot silently enlarge that ceiling. An edit beyond a ceiling
requires an explicitly issued replacement grant.

A grant-control capability also carries a management ceiling. The ability to
pause one's child does not authorize raising that child's rights, administering
the parent, or viewing every grant at the resource. Administrative presets
must explicitly include their management powers rather than acquire them
through an accidental generic path. Retiring a grant-control capability does
not revoke separately issued use authority unless that dependency was part of
the issuance contract.

## Powers and useful presets

The following is the proposed first rights inventory. Phase 1 must map every
wire operation and returned capability to it before implementing the ledger.
A missing operation in that inventory blocks the corresponding vertical slice.

| Resource | Separately meaningful powers | Presets and constraints |
| --- | --- | --- |
| Directory | Browse/watch public listings; register presence and hold a name; request introductions and use authorized signaling; create rooms; publish listings. Access administration remains separate. | Visitor, member, creator, and publisher are bundles of named powers. Creation and publication are distinct. Registration must not imply the right to create rooms. |
| Room | Receive live messages; read retained history; post and edit one's own lines; upload/post files; change topic; issue invitations. Live moderation and grant administration remain separate. | Observer and participant remain useful bundles. Participant can be narrowed, including speak without inviting. Files and topic no longer become unavoidable consequences of speech. |
| Session | Observe live state; request workspace interactions; read retained history and archived files; administer attachment grants. | Observer, collaborator, and administrator are useful bundles, not a required tier hierarchy. Define each from the effects it permits. Session access is also bounded by the room/directory capabilities the session holds. |
| Collection and conversation | List scoped entries; read or post within a discussion; create nested collections; rename or reorganize within authorized source and destination scopes. | Shared collection operations support recursive rooms. Thread views do not introduce a separate implicit authority hierarchy. |
| Message, file, and archive | Read the specified content; obtain authorized attachment facets; edit or withdraw where the source exposes those operations. | Scope identifies the exact content or bounded collection. Reading one item does not grant access to its parent or siblings. |

Typing follows speaking; away/presence and leave follow an active membership.
File upload requires an active membership, file authority, and the room's
resource limits. The policy type refuses impossible combinations rather than
silently adding powers. A room that cannot store files cannot grant uploads.
A delegated moderator can act only within the moderator authority it received.
The new editor must not turn the existing kick capability into permission to
issue stronger memberships without an explicit grant of that power.

Presets are UI conveniences over the authority model. Their expansion and the
operation requirements have one Rust authority, with generated metadata for
the UI and other clients. Unknown rights and malformed policies fail closed.

The [access editor specification](access-editor.md) owns the common
interaction model: permissions, scoped presets, an always-available customizer,
and the separation of policy from lifecycle status. It is part of this plan
and follows the same implementation sequence.

## Delegation and changes over time

### Copies, children, and independent grants

Copying a capability preserves the authority it already carries. When backed
by a managed grant, changing or revoking that grant affects every copy.
Direct sharing of an owner capability preserves its owner powers without
minting a new grant. The system cannot enumerate every person who holds
a copy and must not describe a grant label as proof of a particular recipient.

Issuing a child creates a separately identifiable grant with a bounded ceiling
and a deliberate dependency on its source authority. Within an authority owner,
effective rights and scope are bounded by that ceiling, the child's policy,
and its active ancestors' authority. Parent records name exact owner and grant
generations, form no cycles, and validate subresource scope. Cross-owner
dependencies use the mediation contract in the resource model, not foreign IDs
treated as locally authoritative grant records.

Narrowing or suspending a parent constrains its descendants immediately.
Restoring the parent may restore rights within existing child ceilings; an
explicitly narrowed child stays narrow. Revocation is terminal for the whole
branch even if cleanup has not walked every descendant. Independently issued
grants remain usable. The editor distinguishes a copy from a separately issued
child and previews branch effects without claiming to list unknown holders.

Permission to issue invitations controls minting new admissions. It cannot
prevent forwarding a bearer reference already held, copying received data, or
acting as a proxy. A “cannot share” switch would promise something this model
cannot enforce and must not appear.

### Admission and permission to return

An invitation specifies its offered policy, issuer dependency, claim count,
and whether accepted access lasts for one visit or supports rejoining. These
are distinct choices: a single-use offer can hand back a persistent access
grant without becoming an unlimited invitation to mint more grants.

Admission uses unguessable receipts. Competing receipts race for one admission;
retries with the winning receipt recover the same committed result while that
access remains valid. A lost response cannot mint two accepted grants or leave
a committed admission without a recovery route. Successful admission atomically
records the accepted grant before exposing its authority. Retrying after a
visit has ended or authority has been revoked reports that terminal outcome;
it cannot resurrect access.

The accepted grant retains the intended issuer dependency. Revoking that branch
affects both outstanding offers and access already admitted through it. Merely
closing an invitation to further claims leaves accepted grants intact; the UI
uses different actions for those two effects. A receipt alone is never a public
lookup credential for an accepted grant.

One-visit access ends with its exact live membership. Persistent access can
mint new live memberships within owner-enforced concurrency limits after
reconnection. Multiple copies still exercise the same grant, not verified
personal identity. The browser must retain the exact limited access needed to
return; it must not obtain a broad room link as a recovery shortcut.

The first implementation supports live and persistent lifetimes, single-use
and reusable offers, and explicit suspension/revocation. Timed expiry is not
part of this scope. Adding it requires an owner-defined clock and restart
contract; a browser timer or resource-pressure eviction cannot expire authority.

### Public access and alternate entrances

The published directory entry point provides only intentionally public powers.
An open deployment can expose broad public access; a restricted deployment
must require an explicit grant for additional operations. Merely wrapping the
old root in a narrow facet is insufficient if callers can fetch the full root.

Public room entrances remain policy-selected offers. Changing public admission
invalidates unused old public entrances without silently changing existing,
independently admitted grants. Withdrawal from directory discovery does not
destroy the room. Preserve the separation established by ADR-0139.

Revoking one grant is not a ban on a person. If public admission or a separate
room link still offers access, it remains a valid route. Access editors must
show the resource's public offer and explain when another entrance remains.
Do not introduce account IDs, IP bans, or nickname blacklists to hide this fact.

## Enforcement and revocation

### Check at the owner of the effect

Every protected operation uses a typed admission result tied to the exact
resource, grant generation, and committed revision. Never capture effective
rights only when issuing a reference, opening a dialog, or attaching a view.
Revalidate after an asynchronous wait before committing a protected effect or
returning newly acquired authority. Bounded local lookups must suffice; ordinary
messages cannot require disk I/O or a separate remote authorization service.
Cross-owner facets still make the upstream capability calls their declared
operation requires; local caching cannot replace upstream authority.

Returned capabilities require a declared lifetime relationship. Topic, file,
upload, line-edit, history-reader, directory-watch, name-voucher, signaling,
and session-view capabilities derived under a grant must consult that grant
where they continue to exercise its authority. Authority intentionally issued
as independent must be explicit in the result and in its owning contract.

A session attachment therefore cannot receive raw underlying room capabilities
and still promise that attachment revocation withdraws their use. Keep such
access mediated by the attachment grant. An explicit handoff of independent
room authority is a separate action with a separate revocation boundary.

In particular, a helper that retained its topic or file reference cannot use
that old reference after losing the corresponding power. Promotion may require
new facets to be handed over; a stale null slot is not evidence that the new
policy failed. Observation and facet acquisition must converge on the same
committed revision.

### Define the change boundary

A successful change response means the durable policy, when applicable, has
committed and every new protected admission observes it. Work already committed
before that boundary is not undone. Deferred calls, queued notifications,
partially staged uploads, and pending introductions must recheck authority at
their relevant commit/delivery boundaries. No bytes already delivered can be
recalled, and a separately retained archive remains its own resource.

Suspension denies ordinary resource access while retaining a bounded status
channel that can explain the pause and announce recovery. It carries no live
room content, history, sibling inventory, or continued directory discovery.
Revocation reports a terminal outcome and releases subscriptions and derived
resources. Failure to deliver that notice cannot keep authority usable.

Resource revocation must not close a shared CapTP connection as a shortcut.
The same connection can carry independently authorized rooms, directories, and
attachments. Cleanup cancels only work owned by the affected grant or branch.

For directory grants, retire dependent name registrations, vouchers, listing
leases, pending introductions, and signaling attempts according to their own
contracts. Already-established direct peer capabilities remain independent.
A room grant can remain valid even if withdrawing directory access removes its
usual discovery or signaling route; the UI must distinguish loss of authority
from loss of reachability. Do not promise connection-independent availability.

## Persistence, failure, and cost

Persistent owners must commit authority before publishing it: otherwise a
successful issuance can disappear on restart or a revocation can be undone.
Grant authority belongs in the owner store, separate from ordinary workspace
intent and exports. Each owner has an explicit authority transaction boundary
covering its grants and admissions. A room and its
access records cannot be independently restored into contradictory generations.

Issuance records authority before publishing it. Retrying an operation ID with
the same intent returns the same result; different intent is refused. A policy
change persists before adopting the new committed state. Revocation records
its terminal state before unpublishing, and live behaviors consult the record
so failed publication cleanup cannot restore access.

An interrupted or indeterminate write places the affected owner in recovery
and refuses protected admissions until storage is reconciled. Known-unchanged
writes retain the prior policy. Recovery retires the old storage operation
before reading state again. Crash tests must cover every point between prepare,
persist, publication, live invalidation, observation, and response.

Stable publication entropy must be domain-separated by resource kind, stable
resource identity/generation, grant identity, and publication purpose. A mutable
label or rights field must never determine a grant's locator. Do not invent a
new cryptographic primitive or duplicate the Host's sturdyref mechanism.
Revoked IDs cannot be reused, including after a crash or an exhausted ledger.

Native persistent grants survive restart only with their owning state and
identity intact. Browser-hosted sessions currently use volatile grant state;
retain their explicit tab lifetime. Shared machinery must run in native and
Wasm contexts, but this plan does not silently make a tab durable or add
browser-hosted directory/room services.

Every owner must bound active grants, retained tombstones, invitation receipts,
child count, delegation depth, active seats, watches, pending mutations, and
aggregate bytes. Limits charge against the resource as well as each branch,
so creating more children does not multiply a quota. Retiring a creation grant
does not release the resource cost of rooms that still exist.

The session ledger's current 32-active, 256-lifetime, and 128 KiB document
limits are measurement inputs, not design constraints. Phase 1 sets
measured limits per owner and records startup, message-admission, and large
branch-revocation budgets. An ordinary operation performs no ledger serialization
or allocation proportional to total grants. Paginate inventories with bounded,
revision-aware cursors; stale cursors request a fresh view. Exhaustion refuses
new issuance and never evicts live authority or silently drops revocations.

Logs, traces, snapshots, clipboard affordances, and exports must distinguish
management IDs from bearer secrets. Grant inventories expose only the scope a
viewer administers; ordinary members receive their own effective access. Copying
a use link must never accidentally include its control or root-administration
capability. Deliberately sharing existing owner authority is a separate action.

## User experience

Use one access-management interaction pattern from resource and item details,
including directories, rooms, conversations, messages, files, and sessions.
The editor exposes direct sharing and managed sharing as distinct actions.
Open an
individual grant in a focused editor with explicit save, committed feedback,
and predictable focus return. Reuse the existing Submodal and commitment
components where they support that interaction. Policy remains owned by Rust;
the UI does not acquire a second policy engine.

The inventory shows a label, resource, effective access, lifetime, status, and
any deliberately dependent branch. A live-members list remains a presence
view; it can lead to access records but cannot substitute for an inventory of
offline grants and outstanding invitations. A grant may serve several holders
or seats. Labels such as “wall display” are descriptions, not identity proof.

The editor shows current powers in ordinary language, the limits on editing,
and where a restriction comes from. Useful presets lead; individual controls
allow meaningful narrowing. Moderation, access administration, and ownership
are presented separately from participation. The server's committed observation
confirms changes; the UI cannot announce success from a local checkbox state.

Invitation creation shows the offered powers and lifetime before delivery.
The recipient's acceptance view shows the same contract. Choosing observer
must actually issue observer authority. Closing an offer and revoking admitted
access are separate, accurately worded actions. Reconnect must preserve the
selected access instead of recovering with a stronger invitation or root link.

Pause explains what stops and how it can resume. Revocation previews dependent
grants and live seats when those are visible to the administrator, warns when
the current editor uses that grant, and explicitly describes any public access
that remains. When exact holder counts are unknown, say so. Never imply that
revocation erases data already read or removes every independent route.

Only viewers holding the relevant management capability see edit controls.
Read-only viewers may inspect their own powers. A stale edit carries its base
revision and returns a conflict with a fresh scoped view, preserving draft
intent without overwriting another administrator's change. A dialog targets an
exact grant and resource generation; a reused nickname cannot retarget it.

Support keyboard navigation, focus return, narrow screens, readable refusals,
empty inventories, unavailable owners, partial publication failure, quota
exhaustion, and lost acknowledgements in the first completed UI slice.

## Implementation inventory

The source paths below identify reusable mechanisms and replacement sites for
the model above. They neither establish compatibility requirements nor imply
that the proposed controls already exist.

| Surface | Present implementation | Work this plan owns |
| --- | --- | --- |
| Session grants | The [grant ledger](../../../apps/rooms/rust/application/src/grants.rs) stores rights, history access, suspension, labels, and revocation. [Session facets](../../../apps/rooms/rust/runtime/src/service/facet.rs) consult current access. | Reuse validated persistence and revocation mechanisms where they fit the common lifecycle; replace the session-specific grant contract. |
| Session editing | [SessionGrantEdit](../../../apps/rooms/web/ui/settings/SessionGrantEdit.tsx) edits rights, history, and suspension; SessionAccess issues and revokes grants. | Reuse the interaction structure across resource types. |
| Room memberships | [Seat parsing](../../../apps/rooms/rust/application/src/room/membership.rs) receives observer/participant membership and separate topic/file references. [Room policy](../../../apps/rooms/rust/application/src/server/rooms/membership.rs) enforces the live seat. | Give continuing room access an editable policy independent of a live seat. |
| Invitations | The room can mint observer or participant invitations. [Admission](../../../apps/rooms/rust/application/src/server/invitation.rs) arbitrates competing receipts and one successful subscription. | Durable, individually manageable offers and accepted grants, with explicit lifetime and delegation. |
| Browser invitations | [The sharing gesture](../../../apps/rooms/rust/browser/src/attached/sharing.rs) runs `offerRoom`; its input does not choose membership rights. | Show the authority being offered and stop silently substituting a broad reusable room link for limited access. |
| Directory access | The [directory root](../../../apps/rooms/rust/services/src/server/behavior.rs) offers discovery, registration, creation, introductions, and signaling. A [name capability](../../../apps/rooms/rust/services/src/server/registration.rs) carries registration authority. | Distinguish intentionally public operations from individually granted directory powers. |
| Room administration | Managers control publication and links; moderators can remove a live member. [RoomAccess](../../../apps/rooms/web/ui/cards/RoomAccess.tsx) edits public presets. | Represent moderation and access administration as explicit powers; add exact-grant management and per-membership access inspection. |

[ADR-0137](../../decisions/adr/ADR-0137-durable-rooms-session-grants.md) establishes
the session ledger and persist-before-publication discipline.
[ADR-0139](../../decisions/adr/ADR-0139-rooms-entrances-memberships-and-registration.md)
establishes separate entrances, memberships, and registration, but describes
durable invitations and moderator promotion beyond the current implementation.
The live membership has no editable grant policy or retained grant lineage;
moderation's implemented operation is removal. Implementation must close and
reconcile these differences rather than citing the ADR as execution evidence.

## Implementation owners and protocol changes

| Layer | Responsibility |
| --- | --- |
| Loam and `access` at `src/loam/access/` | Loam owns shared graph persistence and residency; its managed access extension owns resource/access policy, grants, and lifecycle. Integration uses the existing Host and shared Rust binding. |
| `rooms-application` | Rooms content schemas, concrete operation requirements, content facts, permission declarations, presets, admission receipts, and application transactions composing content with access decisions. |
| `rooms-glowcap` | Typed application clients and marshalling of capabilities, methods, and errors through the existing binding. |
| `rooms-runtime` | Reusable lifecycle workers, facet custody, subscriptions, scoped cancellation, and session integration. Move shared directory/room execution here when both owners need it. |
| `rooms-services` | Native directory/room composition and effects; remove duplicated lifecycle decisions as they move into shared owners. |
| `rooms-platform` and `rooms-browser` | Storage, entropy, scheduling, and transport adapters. Neither decides access. |
| `web/ui` | Generated policy metadata, scoped view rendering, form state, navigation, and commitments. |
| Zig Host and OCapN core | Existing reference identity, export/import ownership, handoff, and protocol validation. Application rights stay above them. |

The [library and application boundaries](resource-model.md#library-and-application-boundaries)
defines the library's placement outside `apps/`, its portable modules and
existing Host integration, its dependency direction, and the
content model retained within `rooms-application`. Generic resource/access
contracts remain independent of both chat content and transport execution.

Introduce explicit use and management objects with typed methods for describing
current access, issuing bounded children/offers, editing policy, suspending,
resuming, revoking, and observing scoped changes. Managed access owns these common
application schemas; Phase 1 assigns their names and contracts there. Rooms
owns its content methods and references the common definitions. Inspection by an ID is authorized through a held
management object, never a globally callable grant registry.

Generate the shared managed access application interfaces from their own schema. Update
the [Rooms protocol generator](../../../tools/gen/rooms_protocol.zig) to reference
those definitions, along with generated language tables, browser metadata,
actual clients, and protocol docs in each wire-changing slice. Baseline Syrup remains the common CapTP profile;
application method support is established by the peer, not inferred from its
implementation language. Unsupported access methods produce typed unavailability
and never trigger a retry through a more powerful public or root capability.

Preserve native clients, browser local/attached sessions, the CLI peer, the IRC
front and bridge, and Goblins peers as real consumers. An IRC adapter cannot
invent a stronger grant to emulate a missing channel mode. Peering must publish
the exact entrance supplied by its room owner, not reconstruct authority from
a directory label or a foreign grant record.

## Ordered implementation and exit criteria

The phases implement one settled design; they are not successive public
contracts. The first phase resolves recursive resources, both sharing modes,
and the editor across the supported content types. Later phases divide engineering work, without preserving an
old path or inventing a temporary adapter to make an incomplete surface look
complete. A phase cannot claim system completion while a sibling surface still
uses a bypass or copied authority model.

The [Loam implementation order](../loam/architecture.md#implementation-order-and-acceptance)
owns the shared foundation. Rooms phase 1 refines the application contract in
parallel; phase 2 consumes Loam persistence, sleepy hosting, managed access,
and the foreign/browser interfaces before replacing session access.

1. **Settle recursive resources and the complete sharing contract.** Design
   the inventories, individual editors, invitation/acceptance flow, and
   recipient status view together. Include stable conversation identity,
   source provenance, scope attenuation, direct sharing, durable facets, and
   cross-owner dependencies. Resolve reorganization's identity and audience
   contract from the content plan. Walk the opening scenarios through
   issue, use, change, delegation, reconnect, and revocation. Write an ADR
   amending or superseding the relevant parts of ADR-0137 and ADR-0139. Record
   the exact right-to-method and derived-capability matrix, invitation modes,
   preset groups and their replacement scope, independent controls, Custom
   matching, public defaults, management
   ceilings, persistent schemas, and per-owner budgets. Include source paths
   for every consumer and current recovery route, including what is deleted.
   Exit when the complete interaction contract is reviewable and no operation,
   including history, names, signaling, and returned file/line capabilities,
   lacks a declared authority and retirement owner.
2. **Build the common lifecycle and integrate session access.** First complete
   the record, backend, recovery, and bounded-working-set stages in the
   [managed access acceptance plan](../loam/access/acceptance.md#implementation-sequence-and-exit-evidence).
   Establish those contracts before freezing the hosted API or adding a second
   application persistence path. Implement the
   Zig design at `src/loam/access/`, keeping the resource and access model independent
   of Rooms. Provide runtime schema registration, native Zig helpers, and the
   Rust binding over the same implementation. Integrate existing actors and
   Host APIs without introducing another engine, driver, Host, or event loop.
   Establish content ownership within `rooms-application`, which supplies
   concrete requirements and content facts. Prove the shared Zig model
   with platform-independent fixtures, including a non-chat resource;
   sessions are its first integration, not the template for other resources.
   Include bounded children, explicit management authority, and branch
   administration. Replace the session-specific ledger and editor contract;
   deliver direct sharing and the planned issue/edit/pause/revoke interaction.
   Prove equal-permission managed facets as well as narrower ones. Exit after native
   and Wasm policy/storage proofs, restart and failure injection, and
   retained-reference revocation tests pass. Delete the copied
   or replaced implementation in this slice.
3. **Implement recursive rooms and scoped content access end to end.** Add room-owned grants, admission
   receipts, continuing memberships, dependent facets, manager/moderator
   boundaries, persistent limited invitations, and exact reconnection custody.
   Add recursive collection references, stable conversations, and message/file
   scopes with retained source and sharing context. Ship room access inventory,
   item sharing, member-to-grant inspection, the editor, and
   invitation choice/acceptance together with native client support. Exit when
   a helper can speak without inviting, lose file/topic powers on retained
   references, pause/resume, and reconnect under the same limited grant; branch
   revocation survives restart and separate room grants remain usable. Delete
   replaced membership policies, invitation state, and broad rejoin fallbacks
   in this phase, updating their producers, consumers, and fixtures together.
   A shared message must survive restoration within its declared lifetime
   without exposing siblings, and cross-owner mediation must preserve refusal.
4. **Implement directory access end to end.** Split the public offer from
   additional directory use and management facets. Cover every alternate
   directory verb and registration/signaling path. Ship the directory editor
   and its bootstrap configuration with clients and operating docs. Exit when
   creator access can be revoked while browsing continues under another grant,
   created rooms remain owned, and an independently authorized room/DM on the
   same transport continues through directory grant retirement. Remove the
   unrestricted bootstrap and superseded registration/publication paths in
   this phase wherever they would bypass the declared public policy.
5. **Complete conversation workflows and outside-peer evidence.** Exercise the
   resource owners together, peered rooms, local and durable sessions, multiple attached
   views, all shipped clients, and both IRC edges. Add an interactive Rooms
   conversation view with scoped history, unread state, search, and notification
   behavior, plus rename/split/merge/move under the settled audience contract.
   Treat these as explicit product work, not automatic consequences of OCapN.
   Add a sharing scenario that visibly issues, narrows, passes, and revokes
   real authority.
   It may support the website demonstration, but a static-only browser host or
   new embedding framework is not a prerequisite. Exit when the scenario uses
   production fronts and its claims match automated refusal and survival tests.
6. **Audit completion and retire the plan.** Each owning phase already removes
   its obsolete paths and updates its documentation. Check the composed product
   for overlooked recovery paths, duplicated policy, and stale assumptions.
   Reconcile shipped inventory, known boundaries, protocol pages, operating
   guidance, and ADR links with the verified result. Delete this plan only
   when every completion criterion below has evidence or has
   been explicitly removed from the approved scope.

Prerelease replaces unsupported contracts at their owners. There is no schema
migration workstream, dual reader, legacy wire alias, compatibility shim, or
fallback to earlier authority. Update all in-tree producers, consumers, and
fixtures in the owning slice. The final schema remains version 1 under the
[prerelease rule](../../../.agents/rules/prerelease.md); old experimental formats
do not earn versioned support. Identify affected development stores and the
explicit reset needed to use the replacement. Reset is an operator action,
not automatic deletion or a loader that converts invalid state into empty or
fully privileged authority.

## Verification matrix

These are behavioral requirements for tests, not assertions that they pass now.
Use the portable application contracts as the authority for Rooms policy;
OCapN conformance establishes reference semantics, not the meaning of room roles.

| Scenario | Evidence required |
| --- | --- |
| Allowed and denied operations | Every operation in the rights matrix succeeds with its required authority and is refused without it, through native and browser clients. |
| No public bypass | Refetching bootstrap, using old directory/room entrances, or invoking alternate verbs cannot recover privately withheld powers. Intentionally public access remains available. |
| Exact scope | Foreign resource IDs, old generations, sibling grants, reused names, stale dialogs, and forged view records confer no authority. |
| Delegation | Copies share revocation; bounded children attenuate; parent restriction constrains descendants; parent expansion cannot exceed a child's issuance ceiling; independent grants survive. |
| Invitation admission | Concurrent claims, repeated winning receipts, cancelled waits, server crashes, and lost replies produce exactly the recorded admission. One-visit and rejoin behavior differ as advertised. |
| Live changes | Previously held topic, file, upload, line-edit, history, naming, and watch references obey current rights. Promoted holders can acquire newly allowed facets. |
| Change observation | Committed edits emit scoped events through actors over CapTP; failed/no-op edits emit none. Ancestor changes update descendant views without leaking hidden ancestry. Reconnect and overflow resynchronize; missed events never preserve permission. |
| Pending effects | Revocation during storage, handoff, upload, introduction, signaling, or watch delivery prevents a later unauthorized effect or disclosure; cleanup is bounded. |
| Isolation | Revoking one directory, room, or attachment grant does not close shared transport or retire unrelated memberships and direct conversations. |
| Persistence | Revoked branches remain dead, labels/policy edits preserve links, uncertain writes fail closed, receipt retries recover, and missing/corrupt stores do not remint authority. |
| Resource pressure | Every count/byte/depth limit refuses safely; grant churn cannot bypass aggregate quotas; message admission stays within its measured cost. |
| UI and observation | Scoped inventory, stale revisions, self-revocation, unknown holders, reconnect, keyboard/focus, and narrow layouts render committed facts and clear outcomes. |
| Editor policy | The [editor verification cases](access-editor.md#verification) cover preset replacement, Custom mode, lifecycle independence, and stable issued policy. |
| Resource model | The [resource scenarios](resource-model.md#product-integration-and-verification) cover direct and managed sharing, recursive scope, durable facets, provenance, and reorganization. |
| External consumers | Goblins and shipped language/IRC clients use actual limited references and observe both permitted and refused behavior on baseline CapTP. |

Place deterministic policy tests in `rooms-application` and replay contract
fixtures through `rooms-contract-proofs` natively and in Wasm. Exercise storage
and live ownership in service/platform tests, browser custody through the real
browser exports, and UI through production page proofs. Validate new property
checks against injected defects, including stale cached rights and a bootstrap
bypass, before relying on their green result.

Focused existing checks include `zig build rooms-rust-test`,
`zig build rooms-rust-browser-test`, `zig build rooms-server-test`,
`zig build rooms-peers-test`, `zig build rooms-terminal-client-test`,
`zig build gen-rooms-protocol-check`, and
`zig build rooms-browser-metadata-check`. Browser journeys use
`zig build rooms-web-proofs`; external Rooms checks include
`zig build goblins-rooms` and `zig build goblins-rooms-irc`.

Substantial implementation ends with `zig build check`,
`zig build runtime-check`, and `zig build check-external` for the changed
product and outside-peer surfaces. Any discovered Zig protocol change also
needs its focused oracle evidence before the external check. This plan-only
change requires `zig build source-check`.

## Completion and reusable constraints

Completion means recursive resources support deliberate direct sharing and
separately managed facets without sharing authority accidentally; UI and non-UI callers exercise
it; persistent grants and receipts recover correctly; limited access remains
limited through every returned capability and reconnection path; and the
verification matrix has recorded results on the implementation commit.

The lessons this work must preserve are concrete: membership presence is not
continuing admission authority; matching UI controls do not imply matching
backend enforcement; copying original authority creates no separate grant;
facets retain origin and can be durable; and placement does not establish an
authority parent. This plan records those constraints now. Implementation must turn the
mechanically enforceable ones into typed seams and regression scenarios rather
than leaving them as instructions for the next editor.
