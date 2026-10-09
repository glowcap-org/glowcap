# Rooms authority storage and budgets

Status: active plan. This is the phase 1 persistence contract for
[Rooms access](access-grants.md). Implementation consumes the existing
[Loam record and hosting contracts](../../loam/access.md), after shared Zig and
foreign readiness. The numbers below are admission limits and acceptance
budgets for that implementation, not measurements of unimplemented Rooms code.

## Owner and schema boundaries

An authority owner has one managed owner header and one transaction boundary
over its content and access state. Owned containment stays within that owner;
a directory placement of an independently owned room is a retained capability
link. Several owners can share a Store and cache without merging authority.
Managed resource records own identity and canonical parent; application rows
retain their resource binding instead of duplicating those mutable facts.
An owned nested room uses the containing owner's quota. Creating a new
independent owner requires construction authority and charges the hosting
service's aggregate owner quota. A room outliving its creation grant keeps
that charge until explicit destruction.

Managed resources, grants, controls, endpoints, publication recipes, identity
directories, change history and retry windows use the shared schemas at
`src/loam/access/records/`. Rooms does not serialize another grant ledger.
Its application schema family starts at version 1 and contains these records:

| Record | Payload and retained edges | Transaction owner |
| --- | --- | --- |
| Content root | Owner identity, application schema version, host-incarnation marker, content-index root and configured quotas; strong edge to managed owner header. | Application hosting owner. |
| Collection | Stable resource/generation, label, kind, archived flag, ordered entry-index root and default conversation when it is a room. | Content module; managed resource row owns canonical parent. |
| Conversation | Stable resource/generation, label, archived flag, next commit sequence and message-index root. | Content module with managed structural/content stamps. |
| Message | Stable resource/generation, insertion position, original authored context/time, first creation sequence, body state, reply target and bounded file/provenance edges. | Content module; moving changes parent/position, not identity or authorship. |
| Placement | Stable entry ID, destination collection, order, label, target kind and exact held target edge; optional disclosed source context. | Destination content owner, with authorized removal at source when moving. |
| File | Stable resource/generation, bounded metadata, blob identity/length and committed blob-retention handle. | Content/file owner; reader facets retain grant and projection dependencies. |
| Branch provenance | New/source conversation identities as data, disclosed label/context and optional separately held source-view capability. | New conversation owner; source backlink is an independently authorized effect. |
| Invitation | Stable offer/generation, exact issuer use dependency, separate offer-control descriptor, frozen offered terms/ceiling, visit/continuing mode, single/reusable mode, live/persistent lifetime, next claim sequence, closed flag and bounded claim-result edges. | Admission owner, composed with managed child issuance. |
| Admission result | Exact offer/generation and sequence, receipt digest, canonical intent, result kind and accepted endpoint or runtime seat identity. | Admission transaction; replay requires held offer and exact receipt. |
| Session authority custody | Typed strong fields for exact room access, directory access, archive access, operator roles and accepted offers; workspace records hold only intent and references to these fields. | Session runtime through shared capture/save/restore. |
| Effect receipt | Operation identity, canonical intent, source resource generation, committed result or explicit unresolved outcome and bounded retained result fields. | Existing effect owner, composed with access checks. |

Application indices retain typed strong edges. IDs and display paths cannot
reconstruct authority. Local and foreign saved references follow
[ADR-0182](../../decisions/adr/ADR-0182-held-authority-reference-recipes.md).
A foreign durable save checks that the established sturdyref restores the
actual capability held. Unsupported live references and unsupported receipt
capability kinds refuse before staging persistent content. No fallback captures
an unrestricted parent and saves a client-side path restriction.

Session payload and custody declarations are implemented at
[`content::session`](../../../apps/rooms/rust/application/src/content/session.rs).
Workspace intent stores typed field coordinates, with nonzero slot and
generation encoded as 32 lowercase hexadecimal digits. Custody stores the
actual role references and has no JSON capability codec. Removing a field
releases local custody; reusing its slot under another generation cannot make
old intent select the new reference. Effect outcomes distinguish unresolved,
known-absent and committed results, with bounded retained result fields.
Each effect retains its original session access and exact target references;
changing workspace custody cannot substitute authority during recovery.
Local workspace gestures commit a terminal receipt with the changed intent.
They restore only the original source on replay. Local departures remove
unused selected custody in the same graph transaction. Remaining intent aliases,
independent imports and effect receipt occurrences keep their custody.
Dropping a moderator or manager checks its exact field slot and generation.
Room role selection names an already checked exact field and refuses occupied
role substitution. Archive selection keeps access and optional control explicit;
operator selection holds a bounded key list. Replacement releases unused selected
custody while preserving unrelated imports. Their receipts share the local
transaction and ManageCustody admission. Actual imports retain shared save checks.
Live membership custody includes the inbox and optional seat, topic and file
facets; result recipes keep their original session dependency.
Result import requires the receipt's original source and intent, current command
admission and ManageCustody. It preserves the selected result's role and saved
strong edge in local custody; an occupied coordinate permits only identical
actual authority. The receipt retains its independent occurrence. Atomic graph
staging owns this transfer, and expired live results refuse after restart.
Managed creation retains its exact bootstrap outcome and completed publication
lookups until settlement. RoomAccess and RoomControl results stage together;
temporary creation capabilities and publication text remain execution custody.
Cold unresolved receipts cannot recreate a room or repeat bootstrap issuance.

A terminal failed observation records its bounded reason in the original
receipt with an unknown outcome. Settlement wakes the existing durable
workspace observation; disclosure checks the initiating source and current
authority. The reason survives restart, proves no absence, and permits no
new dispatch. Failures of observation or settlement retain their exact live
worker for recovery. A receipt reader shares the owner's content, grant and
execution feeds, so interruption wakes the original caller even without a
durable write. It returns no capability or evidence of absence.

Unpinned terminal diagnostics may leave the bounded replay window. Immutable
intent includes the original workspace revision, which refuses fresh dispatch
after retirement. Unresolved receipts remain protected. The browser releases
a completed wrapper only after reading its structured diagnostic; a refused
read retains that wrapper for recovery.
Every unresolved effect reserves the diagnostic's maximum encoded growth before
dispatch. Concurrent edits preserve that allowance; settlement releases the
reservation into the actual receipt. Sender reservations already include it.
The declarations allow 256 fields per role and 3,072 custody fields in total,
eight effects and 32 retained
target fields and result fields per effect. The 1 MiB session authority budget still applies
across these records. The
[`session::records` codecs](../../../apps/rooms/rust/application/src/content/session/records.rs)
encode all three families in ordered pages of at most 48 KiB, with at most
64 pages and 1 MiB of payload across a candidate. Custody pages hold at most
64 reference fields. Effect pages retain the original source, targets and
committed result independently of current workspace custody. Data coordinates
must match the separately restored typed fields exactly.

The complete schema registry is generated into browser metadata and opened
together in the Linux proof. C-created managed content has a protected strong
resource binding. Production staging must compose the page graph, its strong
fields and the binding in one shared transaction, admitting the Store's change,
recipe and managed-effect budgets as well as these payload bounds. Startup,
publication restoration and this staging remain in the
[integration queue](integration.md#shared-prerequisite-and-remaining-order);
the codecs alone do not replace production authority storage.

A persistent offer's publication retains its exact offer state. Admission
commits the child grant, endpoint, exact publication when continuing/persistent,
receipt and claim sequence together before exposing authority. The issuer
receives a separate control only when its source permits that management.
Accepted grants retain their source dependency independently of the closed
offer's claimability. Closing cannot drop the source edge or revoke acceptance.

For single-use offers, the first winning receipt/result is retained while the
offer remains recoverable. Another receipt is refused. Reusable offers share a
monotone claim sequence and the last eight results; changed intent conflicts,
an evicted sequence returns ReceiptExpired, and a future sequence refuses.
Clients retain the sequence and 128-bit random receipt before sending.
Replay checks current source/result authority and returns terminal status for
ended visits. An expired retry never mints again. The UI offers an explicit new
request or issuer recovery instead of silently substituting a public link.

Seats, uploads, typing, connection-bound vouchers and signaling exchanges are
runtime state. Restart ends them. Continuing access creates a new seat with
the same grant's policy and history floor. A live browser owner explicitly
reports tab lifetime; saving workspace intent does not make its authority
persistent. Linux and browser storage adapters realize the same transaction
outcomes when durable hosting is supported.

Live grants and offers bind the host-incarnation marker in their endpoint
contract. A durable owner advances that marker once, atomically, before opening
admissions after restart. Old live endpoints and receipt results then refuse
without an eager population scan. Persistent endpoints retain their declared
source lifetime; publication cannot make a live parent or remote target durable.
Marker exhaustion refuses startup rather than reusing an incarnation. Live
records become eligible for bounded retirement after their runtime custody ends.

Unknown writes fence the affected owner until exact backend recovery completes.
Confirmed commit precedes publication activation, notices and success replies.
Known-absent writes discard staged content and retain old authority. Cleanup
after confirmed revocation cannot make a stale retained facet usable. Publication
names and terminal identities follow shared bounded retirement and permanent
name reservations; Rooms adds no forever-growing application tombstone file.

## Reorganization transaction

The [content model](content.md#reorganization-contracts) owns the identity table.
Preview obtains source and destination capabilities, committed revisions and
the exact selection. It lists visible gains/losses from owned-subtree grants,
preserved exact-object grants, and dependencies that will lose coverage. A
separately held AudienceChange control is an Issue/Edit management control
whose scope and ceiling cover the content and affected destination authority.
Reorganize alone cannot authorize newly exposing content to another audience.

An atomic commit requires both placement rights and the applicable management
controls at current revisions. Newly covering grants must fit the explicit
audience-change ceiling. If the caller cannot inspect all relevant local
authority, the preview identifies the uninspectable part and requires the
owner's applicable control; it never invents recipient counts. The owner
checks local grant coverage as part of preparation. Unknown remote holders of
already shared references cannot be enumerated or made part of a global vote.

The commit updates canonical containment, content indices, positions, retained
capability fields and managed change stamps together. Owned-subtree coverage
then follows the new graph. Exact-object grants stay bound to the same object;
their current source dependencies may still deny access after the move.
Creating a branch with no copied messages has no audience-changing content move.

The shared profile permits at most 16 managed effects per transaction. Preview
computes the full structural and content cost before offering Commit. A selection
that exceeds this bound refuses with a capacity explanation. Split and merge
never publish a partly moved conversation through hidden batching. Cross-owner
placement has separately acknowledged insertion and removal; a failed removal
leaves two placements of the same exact authority and reports that partial
outcome. Cross-owner ownership transfer is outside this contract.

## Capacity profile

Each row is a hosting-owner profile, not a new quota per nested resource.
Implementation registers these limits through shared descriptors and executor
budgets. Raising a deployment profile requires the corresponding pressure
measurements and does not expand an existing grant's quota or ceiling.

| Owner profile | Active grants | Open offers | Active seats/views | Watches | Pending protected calls | Aggregate application authority payload |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Directory | 2048 | 128 | 256 registrations | 256 | 8 | 16 MiB |
| Room/content tree | 512 | 128 | 128 seats | 128 | 8 | 4 MiB |
| Session | 64 | 32 | 32 attachments | 32 | 8 | 1 MiB |
| Independently hosted archive | 512 | 64 | 128 readers | 128 | 8 | 4 MiB |

Authority payload counts application offers, claims, custody metadata and effect
receipts. Shared model rows, durable-name reservations, content, blob storage,
and runtime memory are reported separately and have explicit service limits.
Per-grant admission allows at most 32 direct children, depth 16, four concurrent
seats/views and eight watches. Resource containment depth is at most 64.
Derived branches share the original grant's concurrency and byte reservations;
more children cannot multiply its quota. Creating more independent owners also
charges service-wide limits. The initial service profile allows 256 owners,
4096 active grants, 512 seats/views, 256 watches, eight pending protected calls,
32 MiB of application authority payload and 256 MiB of persistent authority
records and reservations. Content and blob limits are separately configured
by the existing storage front. Startup refuses missing aggregate limits.

Each offer has one single-use result or eight reusable results. Each endpoint
uses the existing eight derivation and eight mutation receipt slots. Inventory
and history pages contain at most 32 rows and 64 KiB, with revision-bound cursors.
Managed labels have at most 120 UTF-8 bytes; status explanations have at most
200 UTF-16 units. At most 64 signaling exchanges per directory
remain supported, with the existing 16 KiB description and 4 KiB candidate
limits. These runtime deadlines terminate signaling work, not granted access.

One service uses a shared 64-slot, 64 KiB-per-slot managed record cache, at most
4 MiB of record buffers, and eight in-flight managed calls. It does not allocate
that cache per room. Model-record capacity and transient read slots must fit
the Store lease limit before starting work. A protected call admits at most
64 KiB of application arguments; larger uploads stream bounded chunks through
their file owner and reserve aggregate staging bytes before acceptance.

Terminal payload retirement advances in bounded steps through shared cleanup.
An unavailable terminal identity can remain while an actual held reference
retains it. Name reservations do not shrink on revocation. Quota exhaustion
refuses issuance; it never evicts live grants or reuses terminal identities.
The service has an explicit persistent-byte limit including reservations and
refusal metadata; exhausting it requires operator action rather than deleting
revocation evidence. This replaces the old 256-lifetime-row session cap.

## Cost evidence and implementation acceptance

The Zig [recorded workloads](../../../bench/loam/results.md#recorded-managed-execution-and-restoration-october-2-2026)
exercise 64, 512 and 2048 resources, eight concurrent calls, exact/dependent
foreign references and up to 128 retained facets. They support the selected
pressure populations and cache/window profile. They do not measure Rooms
admission, browser memory, sockets or user-facing latency. Active-grant and
application-byte limits above are selected operating limits to verify.

| Path | Required budget and evidence before implementation completion |
| --- | --- |
| Startup | Open owner headers and publication listeners lazily; no grant/content population scan or restored-seat fan-out. Report reads, peak heap, backend bytes and first-use cost at each owner's full profile. |
| Ordinary message | Resident access evaluation allocates nothing and serializes no ledger. Cold preparation depends on bounded resource/grant depth and index paths, not unrelated grant count. Count application copies, record reads and allocations separately. |
| Grant changes | Owner response follows durable commit; subsequent admissions deny narrowed powers. Show paused-content silence, stale returned facets and independent reference progress. |
| Branch revocation | One authority commit makes every dependent admission fail. Cleanup yields after a bounded shared step; measure reads/writes/heap at maximum child count/depth without eager recursive teardown. |
| Return and reconnect | Restore exact publications without broad links; count foreign calls, retained facets and parked work. Ninth managed call refuses; unrelated work progresses. |
| Churn and storage | Repeated offer/claim/revoke cycles release payload/result edges and staged blobs. Count terminal identities, permanent reservations and service bytes separately; demonstrate refusal at every configured limit. |

Tests use typed Linux and Wasm fixtures for admission policy, then the real
runtime and storage adapters. Publish actual counts and latency distributions
for those paths when they exist. Passing the Zig foundation benchmark alone
cannot close a Rooms implementation phase.
