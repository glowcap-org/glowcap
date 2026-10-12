# Managed access model and API sketch

This contract specifies resource definitions, scope and policy algebra, held
access, and management operations for `glowcap.loam.access`. The notation is
illustrative, and Rust examples describe a consumer of the shared Zig
implementation. For the APIs you can call today, use the
[managed access guide](access.md) and the [C/Rust guide](c-and-rust.md).

## The product an application imports

Managed access provides a resource graph, scoped access grants, and the
machinery that keeps held facets subject to those grants. An application
supplies content, operation meanings, and policy definitions. Host integration
binds those decisions to local or remote capabilities. Loam supplies shared
persistence and residency, and scheduling stays in the Host, Vat, and embedding
executor. The Rust notation below illustrates the wider model and hosting
contract. The implemented [Rust profile](c-and-rust.md) exposes fixed-resource
lifecycle operations under `glowcap::loam` and does not project every API in
this sketch.

There are three API surfaces, with distinct callers:

| Surface | Caller | Purpose |
| --- | --- | --- |
| Model | Application author | Define resources, typed policies, content effects, and persistence transactions without network I/O. |
| Hosting | Application host | Serve the model through real capabilities, enforce calls, and retain or restore publications. |
| Use and management | Local or remote recipient | Call a resource, inspect held access, create permitted shares, and control grants it holds. |

The portable model has no socket, task executor, browser dependency, or global
grant registry. The hosting surface uses glowcap's public reference and actor
interfaces. Sharing an ordinary reference remains an ordinary capability
handoff, and managed access does not replace CapTP identity, retain/release, or
handoff tables.

## Identities, references, and relationships

```rust
// Comparable, persistable names. None of these is authority by itself.
struct OwnerId(/* persistent authority-store identity */);
struct ResourceId { owner: OwnerId, slot: ObjectKey, generation: Generation }
struct GrantId { owner: OwnerId, slot: GrantKey, generation: Generation }
struct EntryId(/* one placement within a collection */);
struct Revision(u64);

// Local or remote authority, constructed only by hosting or capability transfer.
struct Resource<I: Interface> { /* opaque held capability */ }
struct GrantControl<P: Policy> { /* opaque control capability */ }
struct Sturdy<T> { /* bearer publication of exactly T */ }

// Managed access owns structure; applications own the payload stored under a resource ID.
struct ResourceRecord {
    id: ResourceId,
    kind: SchemaId,
    owned_parent: Option<ResourceId>,
}
enum Entry<C> {
    Owned { entry: EntryId, child: ResourceId },
    Linked { entry: EntryId, target: C, context: SharingContext },
}
```

An owned child belongs to the same authority store. A linked entry retains a
capability and may point to another owner. Moving a link changes its
placement. Reparenting owned content is a separate authority-sensitive change.
Resource IDs survive renaming and restart with the same state. Recreating a
destroyed resource uses a fresh generation. A display path never selects an
authority source or reconstructs a capability.

`Resource<I>` is a typed client view over a real reference. Its common resource
operations and application operations are served through that reference, with
generated method namespaces preventing collisions. Types check local API use,
and remote values and replies still require validation. Decoding an ID or
trusting a remote type label does not construct a resource.

## Scope and policy

```rust
enum Scope {
    Object(ResourceId),
    Objects(BoundedSet<ResourceId>),
    OwnedSubtree { root: ResourceId },
    Projection { anchor: ResourceId, relation: RelationId, target: ResourceId },
}
struct Terms<P: Policy> {
    scope: Scope,
    permissions: P::Permissions,
    constraints: P::Constraints,
}
struct GrantRecord<P: Policy> {
    id: GrantId,
    source: SourceAuthority,
    ceiling: Terms<P>,
    configured: Terms<P>,
    delegation: DelegationLimit<P>,
    status: Status,                 // Active, Paused, or Revoked
    revision: Revision,
    lifetime: Lifetime,             // Live or Persistent
    provenance: ProvenanceRecord,
}
enum SourceAuthority {
    Original(OwnerRoot),            // internal root; never caller-supplied
    LocalGrant(GrantId),
    Upstream(DependencyKey),        // binds a retained capability, not an ID lookup
}
```

`Objects` is bounded and canonical. `OwnedSubtree` follows owned containment and
not arbitrary links. It includes future owned descendants, and that continuing
authority is disclosed when issued. A fixed selection uses `Objects` instead.
Reparenting can change subtree coverage, so it requires authorized graph and
audience changes in the same transaction. Scope checks use the committed graph
revision, and no tree move retargets an exact-object grant.

`Projection` represents an application-declared part of an operation, such as
reading an attachment through a message. Its relation is schema-defined and
validated against committed facts, and it is not a traversal from an ID. The
projection retains its anchor's grant dependency and the underlying target
capability. Scope containment alone cannot authorize following a link.

A policy belongs to an authority domain and keeps the same permission keys
across resource kinds. A room grant can therefore derive message-scoped access.
The [implemented kind contract](access.md#policy-and-interface-support) defines support
for exact objects, mixed selections and future owned descendants. Application
projections still require their declared relations and exact content facts.

```rust
trait Policy {
    type Permissions;               // typed view of declared permission keys
    type Constraints;               // typed view of declared constraint fields
    type Requirement;               // typed application effect requirements

    fn descriptor() -> PolicyDescriptor;
    fn encode_requirement(need: &Self::Requirement) -> RequirementExpr;
}
```

Descriptors register bounded permission sets, constraint operators, and fact
relations with the Zig model. Requirement encoding maps application operations
to that vocabulary. Zig owns validation, scope containment, narrowing,
intersection, dependency traversal, and effective-authority evaluation.
Applications do not implement those algorithms through policy callbacks.

Facts provide validated resource metadata under the owner's current
transaction. They are not a network client or an unrestricted mutable store.
Application hooks may supply committed facts or a bounded domain predicate but
cannot override graph scope, grant ceilings, or lifecycle. Unknown schema values
and unsupported combinations fail closed. The shared algebra needs fixtures and
property tests, and each application proves its requirement and fact mappings.

Permissions need not all be Boolean. Constraint intersection chooses the
stricter history boundary or smaller quota. Presets are application-defined
values over this policy. The library owns their descriptor shape and scoped
application rules, and the application owns the meaning of a name such as
Observer.

Effective access is computed from configured terms, issuance ceiling, current
local ancestors, and lifecycle. Remote dependency enforcement stays at the
retained upstream capability. A cached descriptor cannot authorize an act.

## A concrete Rooms definition

```rust
struct RoomsPolicy;
enum RoomsPermission {
    ReadContent, ReadHistory, Post, EditOwnMessage, ReadFile,
    CreateChild, Reorganize, Invite, AdministerAccess,
}
struct RoomsConstraints {
    history: HistoryBoundary,
    max_upload_bytes: u64,
}
enum RoomsRequirement {
    ReadMessage { id: ResourceId, created: Sequence },
    Post { conversation: ResourceId },
    EditMessage { id: ResourceId, author: MembershipKey },
    ReadAttachment { message: ResourceId, file: ResourceId },
    Reparent { child: ResourceId, from: ResourceId, to: ResourceId },
}

trait Interface {
    type Policy: Policy;
    type Call;
    type Reply;
    const SCHEMA: SchemaId;
}
struct Message;
impl Interface for Message {
    type Policy = RoomsPolicy;
    type Call = MessageCall;
    type Reply = MessageReply;
    const SCHEMA: SchemaId = ROOMS_MESSAGE;
}
enum MessageCall { Read, Edit { text: MessageText }, Attachments }
struct MessageData {
    author: MembershipKey,
    created: Sequence,
    text: MessageText,
    attachments: BoundedVec<ResourceId>,
}
```

Rooms supplies `RoomsPolicy` and the operation-to-requirement mapping. An edit
checks author facts against the admitted membership relationship, and a
nickname or caller-provided author field is insufficient. `Attachments` checks
the message scope and returns file facets derived through that access, never
raw stored file references that escape the message grant.

A message share narrows its parent's scope while preserving the applicable
history constraint. The policy evaluates the target message's creation facts.
Creating a new share cannot reclassify an old message as newly posted content.
Passing an independently handed-out reference is a separate operation under the
resource model's direct-sharing contract.

## Consumer and management API

### Creating and hosting resources

```rust
let mut owner = Owner::<RoomsContent, RoomsPolicy>::new(
    entropy.new_owner_id(), limits,
)?;
let mut transaction = store.transaction();
let initial = owner.bootstrap(&mut transaction, |tx| {
    let room = tx.create_root::<Room>(RoomData::new("Development"))?;
    let discussion = tx.create_owned::<Conversation>(
        room, ConversationData::new("Browser reconnection"),
    )?;
    let message = tx.create_owned::<Message>(discussion, message_data)?;
    tx.link(discussion, previously_shared_resource, sharing_context)?;
    tx.expose_original(room)?;
    Ok(message)                       // a name, not a capability for a caller
})?;
let installed = store.commit(transaction.prepare()?).await?;
let ready = installed.result(initial)?;
let registration = access::hosting::register(&glowcap_host, owner, content_handler)?;
let room: Resource<Room> = access::hosting::publish_original(
    &glowcap_host, &registration, ready.root_ticket(),
)?;
```

`bootstrap` is a trusted local operation available only on an empty owner.
The publication ticket is created by that transaction and cannot be constructed
from the returned message ID. Later creation and publication require admitted
capabilities. `create_owned` changes both graph and content under one owner.
`link` retains exact existing access and adds placement without reparenting
the target. `RoomsContent` supplies storage for the concrete payload types.

`hosting::register` installs behavior on the existing Host. Its registration
handle owns no Host, Vat, driver, scheduler, or event loop and cannot close the
Host. Publication uses Host machinery. Restored owners use their retained
identity, publication records, and content instead of `bootstrap`. The typed
resource API also supplies scoped collection listing, opening entries,
insertion, unlinking, and authorized reparenting. Each operation declares
target requirements and bounded cursor and output behavior.

### Using and managing held access

```rust
impl<I: Interface> Resource<I> {
    fn clone(&self) -> Self;         // same authority; no new grant
    async fn call(&self, request: I::Call) -> Result<I::Reply>;
    async fn describe_access(&self) -> Result<AccessView<I::Policy>>;
    async fn derive<J: Interface<Policy = I::Policy>>(
        &self, operation: OperationId, request: ShareRequest<J>
    ) -> Result<Issued<J>>;
    async fn make_durable(&self, operation: OperationId)
        -> Result<Sturdy<Resource<I>>>;
}
struct ShareRequest<I: Interface> {
    target: ResourceId,             // resolved only within the held source authority
    policy: Terms<I::Policy>,
    ceiling: Terms<I::Policy>,
    delegation: DelegationLimit<I::Policy>,
    lifetime: Lifetime,
    initial_status: InitialStatus,  // Active or Paused
    label: BoundedText,
}
struct Issued<I: Interface> {
    access: Resource<I>,
    control: GrantControl<I::Policy>,
    durable: Option<Sturdy<Resource<I>>>,
}
impl<P: Policy> GrantControl<P> {
    async fn inspect(&self) -> Result<GrantView<P>>;
    async fn set_policy(&self, op: OperationId, base: Revision,
                        replacement: Terms<P>) -> Result<GrantView<P>>;
    async fn pause(&self, op: OperationId, base: Revision) -> Result<GrantView<P>>;
    async fn resume(&self, op: OperationId, base: Revision) -> Result<GrantView<P>>;
    async fn revoke(&self, op: OperationId, base: Revision) -> Result<Revoked>;
    async fn children(&self, cursor: Option<Cursor>) -> Result<Page<GrantView<P>>>;
    async fn watch(&self, after: Option<ChangeCursor>)
        -> Result<Subscription<GrantChange<P>>>;
}
```

Holding the invoked reference conveys authority to exercise its grant, with no
additional credential. The internal record ID is how the owner locates the grant
behind that reference. The Zig `GrantUse` and `GrantControl` supply this
binding. The hosted API above remains proposed.

`derive` requires delegation authority on the held source. A resource with use
authority alone refuses it. `Issued.control` is bounded to the branch created.
The recipient receives it only if the issuer shares it. A resource
administrator has a separately held control over the authorized inventory.
`children` and `watch` expose only that control's scope and bounded data.
Changes are committed events. An opaque scoped cursor resumes observation.
Missing retained history requires an authorized snapshot and matching cursor.
The [observation contract](access-architecture.md#observable-access-changes)
defines branch changes, use-facet notices, terminal delivery, and recovery.

`make_durable` requires publication authority and a capable restoration owner.
It publishes the same authority without minting a child grant or adding owner
powers. A volatile owner returns `DurabilityUnavailable`. Persistent issuance
records the grant and publication identity before returning `Issued`.
Durable control publication is an explicit separate action. Copying the use
link never includes it. A control can remain live while its use facet is durable.

Application interfaces supply typed convenience methods such as `message.read()`
over `call`. Only methods a peer implements are usable. An unknown interface or
access method produces typed unavailability and no broader fallback.

## Sharing and editing a message

```rust
// Owner access to a room. Collection browsing yielded message_id under this cap.
let room: Resource<Room> = workspace.room("development")?;

// Same access, including whatever administration this particular reference holds.
recipient.send(room.clone()).await?;

// Independent management, still dependent on the issuing room authority.
let issued = room.derive::<Message>(new_operation(), ShareRequest {
    target: message_id,
    policy: message_read_terms(message_id),
    ceiling: message_read_terms(message_id),
    delegation: DelegationLimit::none(),
    lifetime: Lifetime::Persistent,
    initial_status: InitialStatus::Active,
    label: "design excerpt".into(),
}).await?;
recipient.send(issued.access.clone()).await?;
let durable_link = issued.durable.as_ref().unwrap();

let view = issued.control.inspect().await?;
let paused = issued.control.pause(new_operation(), view.revision).await?;
// New reads through every copy of issued.access now refuse Paused.
// Holding room through an independent grant remains unaffected.
let resumed = issued.control.resume(new_operation(), paused.revision).await?;
issued.control.revoke(new_operation(), resumed.revision).await?;
// Enlivening durable_link cannot recreate working access to this revoked grant.
```

Choosing equal permission sets instead of read-only still creates a separately
managed facet. Its administration can derive only within its dependency and
cannot mint an original reference. Copying that facet keeps the same grant, and
the recipient's knowledge of the source identity does not allow fetching the
source's stronger reference.

The session editor uses `set_policy`, preserving scope when a permission preset
changes. Editing a paused grant keeps it paused. A stale revision returns
`Conflict` with a fresh scoped view. The UI retains the draft. Labels and preset
names never enter publication identity or independently authorize an operation.

## Serving a call and committing its effects

The host adapter obtains a private `Invocation` from the actual called facet.
It contains the local owner binding and source authority. Network input cannot
supply a replacement invocation by serializing a resource or grant ID.

```rust
// Preparation and commit within an owner are serialized; no user callback yields.
let mut transaction = store.transaction();
let staged = owner.stage(&mut transaction, invocation, |tx| {
    let proposal = content.prepare(call, tx.resource_facts())?;
    let admission = tx.require(&proposal.requirements)?;
    content.stage(proposal, admission, tx)
})?;

// For a durable mutation, the combined content/access write must acknowledge.
let installed = store.commit(transaction.prepare()?).await?;
let effects = installed.result(staged)?;
access::hosting::deliver(&existing_host, &registration, effects).await?;
```

`stage` produces a bounded proposed change without modifying committed state
or exposing new capabilities. The private admission is bound to the
invocation, target, requirements, and graph and policy revisions. The
transaction API accepts it only for the prepared operation, and it cannot be
cached as a future permission. Application code is trusted to classify all of
its effects.

Storage executes outside the synchronous model. While a prepared durable
mutation is pending, that owner's conflicting mutations return busy or wait
in the application's bounded command queue. Managed access owns no work queue.
The Loam transaction consumes the successful storage receipt. An uncertain
write fences the owner for recovery, and a known-unchanged failure keeps prior
committed state. Cancellation cannot release a store while it is still writing.

The store commits the content, graph, and grant changes that must be atomic as
one recoverable unit. Several managed changes may join that one unit: each
stage validates against the transaction's current composed owner state, and
every participating change's deltas compose into one owner header mutation.
Prepare each change against the state the previous stages left. A change
prepared against an older revision refuses and the caller aborts, leaving no
partial changes. Two unrelated stores do not satisfy this API, so applications
choose a common transactional store or an explicit coordinator with
demonstrated recovery. There is no distributed transaction across resource
owners.

Ordinary reads require no disk write. Content mutation durability follows the
content owner's declared contract, and a grant check alone does not serialize
the ledger. Live owners use an in-memory commit path with the same validation.
Network publication happens after commit, and a failed publication can be
retried using the committed identity. Revocation is enforced before cleanup
completes.

An asynchronous prerequisite, such as receiving file bytes, is staged first.
The protected effect is admitted afterward against current authority. Delivery
of a queued notification is also checked at delivery. Revocation does not
recall bytes already delivered or reverse an earlier committed content change.

## Returned references and cross-owner operations

`ContentCall.discloseExact` implements the `existing` shape below for a bound
prepared strong edge and refuses undeclared capabilities under
[ADR-0172](../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md).
`ContentCall.discloseDependent` implements the runtime `derived` shape. It keeps
both the invoking endpoint and the stored target as live authority under
[ADR-0173](../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md).
Typed local and foreign fields are implemented through the
[reference preparation API](references.md). The broader typed
transaction output below remains proposed.

```rust
// During an authorized Attachments response, produce a limited output reference.
tx.output().derived::<File>(
    held_file_capability,
    attachment_projection(message_id, file_id),
    file_read_permissions(),
    &admission,
)?;

// A separately authorized direct handoff preserves the held reference.
tx.output().existing(held_file_capability)?;
```

The reply encoder accepts bound output references, not arbitrary resource IDs.
The implemented local `derived` path creates a transient projection endpoint
sharing the existing grant dependency without minting a new editable grant or
writing storage. It propagates the calling facet's lifecycle and validates the
declared projection from message access to attachment access, so an arbitrary
file ID never belongs to an exact-message scope. Underlying file access stays
bounded by the retained file capability. `existing` requires the handler's
declared independent-handoff effect and does not unwrap a capability hidden
behind the caller's facet. The schema and effect tests must cover every
returned-reference path, including nested lists, subscriptions, and saved
continuation objects.

A mediator on another peer holds an upstream capability and forwards allowed
acts through it. Local restrictions can narrow or stop forwarding. Upstream
restrictions remain enforced upstream. A local policy read does not certify
remote availability. Revocation reports success at the owner that
commits it, and a partition is never reported as successful remote revocation.

Provenance consists of disclosed source identity, owner-recorded derivation, and
placement context. Its inspection path returns data or limited navigation
capabilities, and never control over its ancestors.

## Persistence and observable failure

The [resource storage contract](access-storage.md) specifies managed access
record families and the authority requirements on Loam atomicity, bounded
residency, restoration, and reclamation. Capability-valued content fields use the shared
[stored-reference contract](access-storage.md#references-embedded-in-application-content),
so payload, exact authority, and retention edges change atomically.
`OwnerImage` below describes a logical recovery unit. It does not load every
record into RAM or encode a whole-owner snapshot on each write.

```rust
struct OwnerImage<D, P: Policy> {
    owner: OwnerId,
    graph: ResourceGraph,
    content: D,
    grants: GrantState<P>,
    publications: PublicationState,
    dependencies: RetainedDependencies,
    receipts: OperationReceipts,
}
enum AccessError {
    Denied, OutOfScope, Paused, Revoked, Gone,
    Conflict { current: Revision },
    CeilingExceeded, DelegationDenied, QuotaExceeded,
    DurabilityUnavailable, Unsupported, RecoveryRequired,
    OutcomeUnknown { operation: OperationId },
}
```

This is the embedding's typed view of one logical restoration unit. Loam stores
resource and access records alongside application-owned `D`, whose contents are
opaque to the managed access evaluator. The storage implementation can use
pages, a journal, or database transactions, and must preserve the unit's
identity and authority relationships. Retained external dependencies are
restored through their sturdyrefs where available. Recording a live-only
reference does not make it durable.

Operation receipts make issuance and policy changes retryable without minting
extra authority. A retry with changed intent refuses. Quotas bound receipts,
tombstones, graph size, recursion, child grants, pending effects, and inventory
pages. A grant or owner generation is never reused to revive a revoked link.
Error details are scoped so a denied lookup cannot reveal private siblings.

## How this looks in Zig

The policy and interface extension points have direct Zig counterparts, using
compile-time policy parameters and explicit allocators:

```zig
const RoomsPolicy = struct {
    pub const Permissions = std.EnumSet(RoomsPermission);
    pub const Constraints = RoomsConstraints;
    pub const Requirement = RoomsRequirement;

    pub const descriptor: access.PolicyDescriptor = rooms_policy_descriptor;
    pub fn encodeRequirement(need: Requirement) access.RequirementExpr { ... }
};
const Message = struct {
    pub const Policy = RoomsPolicy;
    pub const Call = union(enum) { read, edit: MessageText, attachments };
    pub const Reply = MessageReply;
    pub const schema = rooms_message_schema;
};
const MessageRef = access.Resource(Message);
const MessageControl = access.GrantControl(RoomsPolicy);
```

`MessageRef` is the typed capability view and not a resource ID. Integration
functions use the Host for derive, invoke, publish, and control operations over
it. The portable model underneath still exposes explicit effect preparation:

```zig
const RoomsModel = access.core.Owner(RoomsPolicy, RoomsContent);
var model = try RoomsModel.init(allocator, limits);
defer model.deinit();

var transaction = try store.begin(domain, revision);
const change = try model.stage(&transaction, invocation, .{
    .derive = .{
        .target = message_id,
        .terms = RoomsPolicy.readMessage(message_id),
        .lifetime = .persistent,
    },
});
const prepared = try transaction.prepare();
const ticket = try store.submit(prepared);
// The existing executor returns this batch's outcome to the shared Loam core.
const installed = try store.complete(ticket, backend_outcome);
const effects = try installed.result(change);
try access.hosting.applyEffects(&existing_host, &registration, effects);
```

Neither Rust nor Zig proves the application's requirement mapping, scope laws,
durable commit ordering, or complete mediation of returned capabilities.

## The foreign-language boundary

Rust embeds the Zig implementation through a C ABI. Zig helpers and
foreign typed wrappers use the same runtime registration and access model.
The ABI adds marshaling and ownership work and keeps grant decisions out of the
binding.

The first implemented profile is specified by
[ADR-0185](../decisions/adr/ADR-0185-loam-c-and-rust-resource-lifecycle.md)
and the [consumer guide](c-and-rust.md).
`libglowcap_loam` owns portable Store, Attachment, synchronous Call and submitted
Work handles. The optional `libglowcap_loam_lmdb` supplies LMDB startup and
worker execution. Rust exposes `loam::{Store, Attachment, Content, Policy}` and
uses the existing `Host`, `Ref` and Session types.

| Boundary | Implemented contract |
| --- | --- |
| Policy | Bounded identity, permission keys and lower/upper bounds evaluated by Zig. Callbacks supply content requirements and facts. |
| Callbacks | Copied method tables and trusted bound-resource context. Borrowed synchronous invocations cannot unwind or reenter Host driving. Registration contexts survive until successful detach. |
| Storage | Opaque content replacement joins the shared managed transaction and receipt. Startup creation commits before returning usable metadata. |
| Memory | Input borrows end at callback return. Reply and replacement bytes copy into the bounded retained arena. Fixed Work slots retain submitted buffers until physical retirement, completion and release. |
| Capabilities | Restored endpoints acquire ordinary held Host references. Serialized object names are trusted metadata and never network invocation authority. |
| Completion | Core tickets retain generation and phase checks. Completion reports consumption explicitly. Refusal preserves ownership. Unknown writes select recovery only after the original worker retires. |

The tested consumer lifecycle includes delegated sharing, narrowed admission,
content edits and durable mutation replay, ancestor pause/resume, restart and
cold fetching the original derived publication. C tests exercise release
refusal, duplicate completion and the indeterminate-write recovery barrier.

The fixed-resource profile also projects strong reference authoring and exact
or dependent restoration through shared Host preparation. Its
[consumer guide](c-and-rust.md) owns bounds and scope. General object and graph
transactions, application-specific derivation decoders, privileged owner
lifecycle, and the broader hosted sketches above are not projected. Each is
added for an exercised consumer path, with the shared storage and authority
contracts intact. The [browser profile](browser.md) exercises the same
fixed-resource lifecycle. These consumer proofs do not freeze the broader
interfaces.

Rust traits and Zig compile-time types provide typed views over registered
schemas and construct requirements for the same runtime model. The vocabulary
includes constraint bounds and fact relations as well as permission sets.
New general operators belong in Zig with shared tests. Unsupported semantics
do not fall back to a Rust evaluator.

Remote use is a different boundary. A Goblins or Python peer can call the
published managed access application interfaces over OCapN without embedding
this model or its C ABI. Those wire interfaces still need documented schemas
and outside-peer evidence independent of the implementation language.

## Decision and implementation evidence

The [access architecture](access-architecture.md) specifies one Zig implementation
within Loam, with Rust bindings and Host integration. Applications supply
content and operation meanings, and Zig owns generic resource and access
decisions.

Review complete paths through issuance, restoration, ancestor edits, returned
attachments, reorganization, and lost storage acknowledgements. Measure ABI
calls, copying, allocation ownership, and Linux/Wasm behavior. Verify that
Rust wrappers execute selected effects without reconstructing the grant model.

The broader illustrative APIs above have not been compiled or benchmarked. Their
implementation must validate policy laws, capability custody, transaction
boundaries, and failure paths against the [access evidence
matrix](access-architecture.md#implementation-evidence) and [Rooms integration
scenarios](../planning/rooms.md#verification-matrix) before claiming guarantees.
