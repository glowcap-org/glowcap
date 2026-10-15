---
type: static
description: The model and API sketch for managed access, covering resource definitions, scope and policy rules, held access, and management operations.
audience: human
sources:
  - resource: /src/loam/access/
  - resource: /bindings/rust/src/loam/
---

# Managed access model and API sketch

This page sketches how an application defines resources, scopes, policies,
held access, and management calls in `glowcap.loam.access`. The notation is
illustrative, and the Rust examples show code that uses the shared Zig
implementation. For the calls you can make, see the
[managed access guide](access.md) and the [C and Rust guide](c-and-rust.md).

## What an application gets

Managed access gives an application a tree of resources, grants that cover
parts of it, and the machinery that keeps every held facet within its grant.
The application supplies the content, what each operation means, and its
policies. The Host turns those decisions into local or remote capabilities.
Loam stores everything and decides what stays in memory, and the Host, Vat,
and your program's executor do the scheduling. The
[Rust API](c-and-rust.md) covers creating, using, and retiring fixed
resources under `glowcap::loam` and does not offer everything sketched here.

Three kinds of code call into it:

| Part | Caller | What it does |
| --- | --- | --- |
| Model | Application author | Defines resources, typed policies, content changes, and transactions, with no network I/O. |
| Hosting | Application host | Serves the model as real capabilities, checks calls, and keeps or restores durable names. |
| Use and management | Local or remote holder | Calls a resource, inspects its own access, makes permitted shares, and controls the grants it holds. |

The model has no socket, task executor, browser dependency, or global list
of grants. Hosting uses glowcap's public reference and actor interfaces.
Passing an ordinary reference is still an ordinary capability handoff, and
managed access leaves CapTP's identities, reference counts, and handoff
tables alone.

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

- An owned child belongs to the same owner.
- A linked entry holds a capability and may point to another owner. Moving a
  link changes only where it sits.
- Moving owned content to a new parent is a separate change that needs its own
  permission.
- Resource IDs survive renames and restarts. A resource created again after
  it was destroyed gets a new generation.
- A display path never picks where authority comes from or rebuilds a
  capability.

`Resource<I>` is a typed client view over a real reference. Common resource
calls and application calls both go through that reference, and generated
method namespaces keep their names apart. Types check local use of the API,
but remote values and replies still need checking. Decoding an ID, or
trusting a type label a remote peer sent, never produces a resource.

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

`Objects` is a bounded set kept in a fixed order. `OwnedSubtree` follows owned
children, not links. It also covers children added later, and the issuer is
told so when the grant is made. Use `Objects` for a fixed set. Moving a
resource can change which subtrees cover it, so a move needs permission for
both the tree change and the change in who can see it, in the same
transaction. Scope checks use the committed tree, and moving a resource never
redirects a grant for one exact object.

`Projection` covers a relation the application declares between two
resources, such as reading a file attached to a message. The schema defines
the relation and checks it against committed facts, so it is never a walk
from a raw ID. A projection keeps its anchor's grant and the capability to
the target. Being inside a scope is never enough to follow a link.

A policy belongs to one owner and keeps the same permission keys across
resource kinds, so a room grant can create access to one message.
[Policy and interface support](access.md#policy-and-interface-support) says
how a grant covers one object, a chosen set, and children added later.
Application projections still need their declared relations and the exact
content facts.

```rust
trait Policy {
    type Permissions;               // typed view of declared permission keys
    type Constraints;               // typed view of declared constraint fields
    type Requirement;               // typed application effect requirements

    fn descriptor() -> PolicyDescriptor;
    fn encode_requirement(need: &Self::Requirement) -> RequirementExpr;
}
```

A descriptor registers the permissions, constraint operators, and fact
relations a policy uses with the Zig model, and requirement encoding maps
application operations onto them. Zig owns checking, scope containment,
narrowing, intersection, walking dependencies, and working out the access in
effect. Applications never implement those through policy callbacks.

Facts are checked resource metadata read inside the owner's current
transaction. They are not a network client or a store anyone can write.
Application hooks can supply committed facts or a bounded check of their own,
but cannot override the tree scope, a grant's limits, or its status. Unknown
schema values and unsupported combinations are refused.

Permissions need not all be on or off. Intersecting two constraints keeps the
stricter history limit or the smaller quota. Presets are values the
application defines over its policy. The library owns their shape and how
they apply to a scope, and the application decides what a name such as
Observer means.

The access in effect comes from the grant's own terms, the limit it was
issued with, the local grants above it as they are now, and its status. A
grant that depends on a remote one is enforced by the remote capability it
holds, not locally. A cached description never authorizes anything.

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

Rooms supplies `RoomsPolicy` and the mapping from each operation to its
requirement. An edit checks the author against the caller's membership, so a
nickname or an author field from the caller is not enough. `Attachments`
checks the message scope and returns file facets made through that access,
never raw stored file references that would escape the message grant.

Sharing one message narrows the parent's scope and keeps its history limit.
The policy checks when the message was created, so a new share cannot make an
old message count as newly posted. Passing on a reference handed out some
other way is a separate operation under the rules for direct sharing.

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

`bootstrap` is trusted local code that runs only on an empty owner. The
transaction creates the durable name's ticket, which cannot be built from the
returned message ID. Later creates and publications need capabilities that
allow them. `create_owned` changes both the tree and the content under one
owner. `link` keeps the exact access it was given and adds a placement
without moving the target. `RoomsContent` stores the concrete payload types.

`hosting::register` installs behavior on the existing Host. The registration
handle owns no Host, Vat, driver, scheduler, or event loop and cannot close
the Host. Durable names use the Host's own machinery. A restored owner uses
its saved identity, durable names, and content instead of `bootstrap`. The
typed resource API also lists a collection within scope, opens entries,
inserts, unlinks, and moves resources where allowed. Each call declares what
it needs on its target and bounds its cursor and output.

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

Holding the reference you call is the permission to use its grant, with no
other credential. The owner finds the grant behind that reference by its
internal record ID. Zig's `GrantUse` and `GrantControl` make this link, and
the hosted API above is still a proposal.

- `derive` needs permission to share on the held source. A resource with use
  permission alone refuses it.
- `Issued.control` covers only the branch it created. The recipient gets it
  only if the issuer passes it on.
- A resource administrator holds a separate control over the grants it may
  see. `children` and `watch` show only that control's scope and bounded
  data.
- Changes are committed events. An opaque cursor scoped to the holder resumes
  watching, and if the history it needs has expired, the holder gets a fresh
  snapshot and a matching cursor.
  [Observable access changes](access-architecture.md#observable-access-changes)
  covers branch changes, notices to use facets, the final notice, and
  recovery.
- `make_durable` needs permission to publish and an owner that can restore
  the reference. It publishes the same access without creating a child grant
  or adding owner powers. A volatile owner returns `DurabilityUnavailable`.
- A persistent share records the grant and its durable name before returning
  `Issued`.
- Publishing a control durably is a separate step. Copying the use link never
  includes it, so a control can stay live-only while its use facet is durable.

Application interfaces add typed helpers such as `message.read()` over
`call`. Only methods a peer implements can be used. An unknown interface or
access method returns a typed error and never falls back to something
broader.

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

Choosing the same permissions instead of read-only still creates a separately
managed facet. Its control can share only within its own grant and cannot
create an original reference. Copying that facet keeps the same grant, and
knowing the source's identity does not let the recipient fetch the source's
stronger reference.

The session editor calls `set_policy`, which keeps the scope when a
permission preset changes. Editing a paused grant leaves it paused. A stale
revision returns `Conflict` with a fresh view, and the UI keeps the draft.
Labels and preset names never become part of a durable name or allow
anything on their own.

## Serving a call and committing its effects

The host code gets a private `Invocation` from the facet that was actually
called. It carries the local owner and the grant behind the call. Network
input cannot swap in another invocation by sending a resource or grant ID.

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

`stage` produces a bounded proposed change without changing committed state
or handing out new capabilities. The private permission result is tied to the
invocation, the target, the requirements, and the tree and policy revisions.
The transaction accepts it only for the operation it was prepared for, and it
cannot be cached as permission for later. Application code is trusted to
declare all of its effects.

Storage runs outside the synchronous model. While a durable change is
pending, other conflicting changes to that owner return busy or wait in the
application's bounded command queue. Managed access owns no work queue. The
Loam transaction takes the storage result when it succeeds. An unknown write
stops the owner until recovery, and a write known to have changed nothing
keeps the earlier committed state. Canceling cannot release a store while it
is still writing.

The store commits content, tree, and grant changes that must happen together
as one recoverable unit. Several managed changes can join that unit. Each
one checks against the owner state the earlier ones left in the transaction,
and all of them merge into one update to the owner's header. A change
prepared against an older revision is refused, and the caller aborts with
nothing written. Two unrelated stores cannot do this, so an application uses
one shared store or its own coordinator with proven recovery. There is no
distributed transaction across owners.

Ordinary reads write nothing to disk. How durable a content change is follows
the content's declared rules, and a permission check alone writes nothing. A
live-only owner commits in memory with the same checks. Durable names are
published after the commit, and a failed publication can be retried with the
committed identity.

Work that must wait on something first, such as receiving a file's bytes, is
written first. The protected change is then checked against current
permissions. A queued notification is also checked when it is delivered.
Revoking a grant does not take back bytes already delivered or undo an
earlier committed change.

## Returned references and calls across owners

`ContentCall.discloseExact` implements the `existing` form below for a strong
field the call declared, and refuses capabilities it did not declare
([ADR-0172](../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)).
`ContentCall.discloseDependent` implements the `derived` form at run time. It
keeps both the endpoint that was called and the stored target live
([ADR-0173](../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)).
Typed local and remote fields work through the
[stored capability field API](references.md). The broader typed transaction
output below is still a proposal.

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

The reply encoder accepts these output references, never arbitrary resource
IDs. The local `derived` path creates a short-lived endpoint that shares the
existing grant, without creating a new editable grant or writing storage. It
follows the calling facet's status and checks the declared relation from
message access to file access, so an arbitrary file ID never falls inside a
one-message scope. Access to the file stays within the stored file
capability. `existing` needs the handler to declare a direct handoff and
never unwraps a capability hidden behind the caller's facet. Schema and
effect tests must cover every way a reference can come back, including
nested lists, subscriptions, and saved continuations.

A go-between on another peer holds a capability from upstream and forwards
the calls it allows. Local limits can narrow or stop forwarding, and limits
upstream stay enforced upstream. Reading a local policy says nothing about
whether the remote side is available. A revoke reports success at the owner
that commits it, and a network split is never reported as a successful
remote revoke.

Where a share came from is made of the source identity it reveals, the
sharing the owner recorded, and where it was placed. Inspecting it returns
data or limited navigation capabilities, never control over the grants above
it.

## Storage and the errors callers see

[Resource storage](access-storage.md) describes the managed access records
and what they need from Loam's transactions, memory limits, restoring, and
collection. Capability fields in content use the shared
[stored reference rules](access-storage.md#references-embedded-in-application-content),
so the payload, the exact access, and the edges that keep things alive
change together. `OwnerImage` below describes one logical unit that recovers
together. It never loads every record into memory or writes a snapshot of the
whole owner on each change.

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

This is your program's typed view of one unit that restores together. Loam
stores resource and access records beside the application's own `D`, which
the access checks never look inside. The storage can use pages, a write-ahead log,
or database transactions, as long as it keeps the unit's identity and
permission links. Outside dependencies are restored through their sturdyrefs
where they have one. Recording a live-only reference does not make it
durable.

Receipts make sharing and policy changes safe to retry without creating
extra access. A retry with different arguments is refused. Quotas limit
receipts, removed-record markers, tree size, nesting, child grants, pending
changes, and listing pages. A grant or owner generation is never reused to
bring back a revoked link. Error details are scoped, so a refused lookup
cannot reveal private siblings.

## How this looks in Zig

The policy and interface extension points have direct Zig counterparts, with
policies as compile-time parameters and explicit allocators:

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

`MessageRef` is the typed capability view, not a resource ID. Hosting
functions use the Host to derive, invoke, publish, and control through it.
The model underneath still prepares each change explicitly:

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

## The foreign-language boundary

Rust uses the Zig implementation through a C ABI. Zig helpers and typed
wrappers in other languages share one registration and access model. The ABI
adds data conversion and ownership handling and leaves every permission
decision out of the binding.

[ADR-0185](../decisions/adr/ADR-0185-loam-c-and-rust-resource-lifecycle.md)
and the [C and Rust guide](c-and-rust.md) define what you can call.
`libglowcap_loam` owns the Store, Attachment, synchronous Call, and submitted
Work handles. The optional `libglowcap_loam_lmdb` and `libglowcap_loam_sqlite`
open storage and run the worker. Rust offers
`loam::{Store, Attachment, Content, Policy}` and uses the existing `Host`,
`Ref`, and Session types.

| Part | What exists |
| --- | --- |
| Policy | A bounded identity, permission keys, and lower and upper bounds, checked by Zig. Callbacks supply content requirements and facts. |
| Callbacks | Copied method tables and a trusted context for the bound resource. Borrowed synchronous calls cannot unwind or drive the Host again. Registration contexts stay alive until detach succeeds. |
| Storage | Replacing opaque content joins the shared managed transaction and receipt. Creating a store at startup commits before any metadata is usable. |
| Memory | Borrowed inputs end when the callback returns. Reply and replacement bytes are copied into the bounded call memory. Fixed Work slots keep submitted buffers until the worker is done, the result is delivered, and the slot is released. |
| Capabilities | Restored endpoints get ordinary held Host references. Serialized object names are trusted metadata and never permission to call over the network. |
| Completion | Tickets keep their generation and phase checks. Delivering a result says whether it was taken. A refusal leaves ownership with the caller. An unknown write moves to recovery only after the original worker finishes. |

The C and Rust API can also write strong reference fields and restore them
as exact or dependent references through the Host. The
[C and Rust guide](c-and-rust.md) gives the limits and what it leaves out,
and the [browser guide](browser.md) runs the same lifecycle.

Rust traits and Zig compile-time types give typed views over registered
schemas and build requirements for the same model. The vocabulary covers
constraint bounds and fact relations as well as permissions. New general
operators belong in Zig with shared tests, and nothing unsupported falls back
to a Rust implementation.

Calling from another peer is a different boundary. A Goblins or Python peer
can call published managed access interfaces over OCapN without running this
model or its C ABI. Those wire interfaces still need documented schemas and
tests against outside peers, whatever language implements them.

## What is decided and what is tested

[Managed access architecture](access-architecture.md) places one Zig
implementation inside Loam, with Rust bindings and Host integration.
Applications supply content and what operations mean, and Zig owns the
general resource and access decisions.

The broader APIs sketched above have not been compiled or measured. Neither
Rust nor Zig proves an application's requirement mapping, its scope rules,
the order of durable commits, or that every returned capability is checked.
Check them against the [managed access tests](access-architecture.md#tests)
before relying on them.
