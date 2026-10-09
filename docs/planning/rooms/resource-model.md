# Resources and sharing in Rooms

Status: active plan. This document owns the resource and sharing model for the
[access-grants implementation plan](access-grants.md). The
[roadmap](../../roadmap.md#durable-applications) owns its priority. These are proposed
contracts; implementation phases serve this model without preserving earlier
unreleased APIs or storage formats.

## The shared model

Shareable Rooms resources support two distinct actions: pass an existing
capability, or issue a separately managed facet. This choice applies to
sessions, directories, rooms, conversations, messages, files, and archives
where their interfaces support the requested use. The session owner's
reference and its separately minted attachment facets motivate the interaction.

| Action | Authority received | Management consequence |
| --- | --- | --- |
| Share existing access | The authority carried by the exact reference being passed. Passing an owner capability includes its owner powers; passing a limited facet keeps its limits. | Both holders use the same authority. Copying creates no separately revocable recipient grant. Existing restrictions affect every copy. |
| Create managed access | A new facet with an explicit scope, permissions, issuance ceiling, and relationship to the issuer's authority. | Its grant can be edited, paused, or revoked independently within that relationship. It can initially permit the same operations as its source, or fewer. |

Direct sharing does not transfer exclusive ownership or create an account for
the recipient. Equal authority through the shared reference does not imply
possession of unrelated capabilities the sender holds. Likewise, a facet does
not have to start read-only: separate management is useful even when its initial
permissions equal the source's delegable powers.

Equal permissions means the same allowed operations within the facet's scope
and dependency. Its administration cannot mint an unrestricted source reference
or independent grants that escape that dependency. Directly sharing the facet
copies the facet; it does not unwrap the original capability.

Use the name facet for an authority-bearing interface. A visual facade or
projection may render that interface, but rendering alone supplies no access
restriction. The original capability remains available for deliberate direct
sharing; the product does not force every handoff through a new grant ledger.

## Independent dimensions

| Dimension | Contract |
| --- | --- |
| Resource identity | The object or scoped content represented, independent of display name and placement. |
| Access | The exact capability being held, including whether it is directly shared or backed by a separately managed grant. |
| Persistence | Whether the hosting owner can restore that reference and its required state after runtime loss. |
| Provenance | The recorded source object, issuing authority, and sharing context that the observer is permitted to inspect. |

Both original capabilities and managed facets may be live or durable. Minting
a facet neither erases the source nor implies a temporary lifetime. A sturdyref
provides a way to recover the corresponding capability; its presence does not
imply owner authority. A durable limited share must recover the limited facet.

Scope is part of the policy alongside permissions. A message grant may allow
reading one message, a conversation grant may allow posting within one
discussion, and a room grant may cover its declared collection. Each type
defines its scope ordering and attenuation. A preset cannot expand the target
scope or management ceiling implicitly.

## Recursive composition

The [content and interaction model](content.md) owns the product schema,
branching, reorganization, and directory/room/conversation UX. A room contains
conversations, nested rooms, and shared entries. Every published message belongs
to one canonical conversation; messages appear elsewhere through references. Collection operations provide a common navigation interface;
resource-specific capabilities define what can be done with each item.
Directories emphasize discovery, rooms participation, and conversations a
focused discussion. Their useful defaults do not establish a fixed nesting
depth or require every item to support every collection operation.

Reference-bearing collection entries carry the exact access being presented.
Labels, message bodies, and other ordinary values remain data. This model does
not require a dedicated actor, ledger, or durable publication per displayed
message; a resource owner can issue scoped facets over its existing storage.

Give conversations stable identities and editable titles. A thread is a named
conversation within this recursive structure, rather than a privilege encoded
in a title or a dependency on the continued existence of its first message.
The room-wide subject/header remains a separate property.

The presentation can be a tree, while references allow an object to appear in
more than one place. Owned containment rejects cycles. Referenced links may
lead back to an earlier object; traversal detects revisits and obeys depth,
page, and work budgets. Neither traversal order nor the first displayed parent
chooses a new source of authority.

Moving an entry changes placement. It preserves resource identity, held
authority, and recorded source. A content operation that changes its audience
is an explicit publication or grant operation. The [reorganization contracts](content.md#reorganization-contracts) define
split, merge, and move behavior, including canonical membership, scope changes,
and existing grants. Moving original content differs from moving a placement.

## Sharing a message through its parent

A parent can issue a facet scoped to one of its messages. The recipient can
use that facet without receiving the parent's unrestricted capability or
access to siblings. Shareable files and other capabilities returned by the
message obey the same declared scope and dependency.

If that message facet is shared into another room, the destination retains the
facet and its disclosed source context. The originating resource remains the
source; the destination records where the share was placed. A subsequent
managed reshare records a new derivation edge. Directly forwarding the same
facet keeps the existing grant and does not invent a new issuance event.

Provenance inspection exposes only authorized context. A limited message share
need not disclose a private parent title, member list, or management reference.
Owner-recorded origin and derivation support explanation and navigation; they
are not proof of every forwarding event or independent verification of human
authorship. Copying delivered text creates data outside that live reference's
revocation boundary.

An access inspector can therefore distinguish the source object, the access
currently held, the context in which it was shared, and the control available
to the viewer. Looking at provenance never confers the ancestor's authority.

## Dependency and durable ownership

A derived grant stays within its source authority. Each manager may administer
only its authorized scope or descendants; it cannot expand an ancestor,
silently enlarge a child's issuance ceiling, or control an independent grant.
Copying a direct reference introduces no extra manager into that chain.

Resources may share one authority store. Within that owner, typed grant records
can narrow access to subresources without a remote authorization lookup. Parent
edges identify the exact grant and generation, and scope attenuation must be
valid for the target. Merely sharing a process or collection creates no edge.

Across owners, an explicit mediating facet can retain and exercise an upstream
capability. It must preserve the upstream restriction on returned references
and later effects. A remote grant ID or provenance description cannot replace
that capability, and an independently issued downstream capability must not
be described as dependent. Shared lifecycle code owns local state; it does not
invent an atomic transaction across peers.

The owner enforcing a mutation acknowledges its commit. If that owner cannot
be reached, the caller sees an unresolved or failed operation, not a successful
global revocation. A mediator unable to exercise its upstream capability cannot
bypass it through a stronger entrance. Cross-owner operations retain the normal
cost and availability of the capability calls they actually make.

A nearest durable ancestor can serve as the restoration owner for descendants
whose state it owns. It retains stable target identities, scoped authority, and
derivation state. A share exposes a publication of the exact intended capability,
never an unrestricted ancestor locator plus a client-supplied path restriction.
External references retain their own declared lifetime. A durable collection
cannot make a volatile remote object survive its host.

## Library and application boundaries

The [Loam foundation](../loam/architecture.md) supplies shared graph persistence
and bounded residency. Its [managed access extension](../loam/access/architecture.md), at
`src/loam/access/` and exposed as `glowcap.loam.access`, owns resource access and
lifecycle management. Its core remains independent of actors and I/O; its hosting
functions register behaviors on the existing glowcap Host. No additional
engine, driver, Host, Vat, scheduler, or event loop is introduced.

| Owner | Responsibility |
| --- | --- |
| Loam | Shared records, typed capability fields, retention, bounded residency, and atomic transactions; persistence integration uses existing actors and Host. |
| managed access core | Resource identity, containment, scopes, shared policy algebra, grant dependencies, ceilings, lifecycle, and authority transactions. |
| managed access hosting integration | Actor behaviors and derived references governed by the core, using existing Host publication, dispatch, and reference custody. |
| Optional Rust binding | Typed wrappers, schema registration, error conversion, and effect plumbing over the Zig implementation. |
| `rooms-application::content` | The proposed coherent owner for Rooms content identities, collections, conversations, messages, and source/placement records. |
| Other `rooms-application` domain modules | Permission meanings, presets, operation requirements, committed content facts, invitation admission, and content effects. |
| `rooms-runtime` and adapters | Compose content operations with managed access admission in Loam transactions; realize shared storage effects through existing executors and execute application effects. |

The portable Rooms content model remains free of Host and executor dependencies.
Its runtime integrates the shared model through the Rust binding. Content
records do not acquire grant lifecycle state, and grants do not acquire message
bodies or rendering rules. An application supplies requirements and committed
facts; Zig performs generic scope, narrowing, intersection, and lifecycle
checks. Possession of an ID still cannot substitute for a capability.

A resource may have several actor-backed access paths and may outlive their
runtime instances. Ordinary actors need no resource record. The architecture
sketch owns that relationship and the Zig/binding implementation boundary;
the [API sketch](../loam/access/api.md) illustrates the consumer contract.

The managed session integrates Rooms content with shared Loam resources,
policy and grant state. Recursive room and directory resources remain in the
[ordered integration plan](access-grants.md#ordered-implementation-and-exit-criteria).
The [application crate](../../../apps/rooms/rust/application/src/lib.rs) owns
[message identities](../../../apps/rooms/rust/application/src/room/message.rs),
[line behavior](../../../apps/rooms/rust/application/src/room/line.rs), files,
archives, and session models. Its
[checkpoint conversation type](../../../apps/rooms/rust/application/src/session/checkpoint/model.rs)
describes workspace conversations, not the complete recursive resource model.
The [managed workspace](../../../apps/rooms/rust/application/src/content/session/workspace.rs)
stores session intent and typed custody; shared Loam owns its grant policy.

The [Rust binding](../../../bindings/rust/src/session.rs) already exposes
`Session::caretaker` and `Session::attenuate` for revocable forwarding and
verb filtering. Reuse these mechanisms where their contracts fit. Their
existence does not supply persistent grant policy, recursive content scope,
or restrictions on every capability returned by an application method.
The new library owns those application-level decisions without copying CapTP
reference tables or adding resource policy to the binding or Zig protocol core.

Extend the content module within the existing application crate to recursive
resources. Shared Loam and its binding own reusable resource/access behavior;
the application crate retains content ownership.
A separate content crate would need an independent consumer or dependency constraint that
the existing application boundary cannot serve.

Portable contract tests use typed fixtures with no Rooms imports, including a
non-chat resource, and run on Linux and in Wasm. Application tests
prove concrete permission meanings and content mutations. Runtime tests prove
that actual held facets enforce those decisions. Dependency checks forbid
Rooms dependencies anywhere in the library and binding/host dependencies in
its portable model modules. No compatibility
re-export leaves the replaced session ledger as a second policy owner.

## Product integration and verification

The [editor specification](access-editor.md) owns the two sharing actions
and the managed facet's permission controls. Search, history, unread views,
notifications, previews, and navigation must consume the same scoped authority;
no aggregate view may reveal siblings that the underlying facet withholds.

The application model belongs above OCapN. glowcap carries and invokes the
capabilities; transport adapters, including iroh, provide reachability. Generic
resource/access machinery belongs in managed access; concrete permission meanings,
conversation structure, and sharing controls remain application-owned.

These scenarios join the parent plan's implementation verification matrix:

| Scenario | Evidence required |
| --- | --- |
| Direct sharing | Original authority is preserved. Copying a limited facet stays limited, creates no new grant, and shares that grant's existing revocation boundary. |
| Managed sharing | Equal-permission and narrower facets can both be separately administered. Their references remain stable through allowed edits and suspension. Administrative operations cannot mint an escape from the source dependency. |
| Persistence | Live and durable access are exercised for both sharing modes where the owner supports them. Restoring a limited share never recovers broader access. |
| Recursive scope | Nested rooms and repeated references preserve exact scopes; forged paths, aliases, cycles, and reparenting cannot amplify access. |
| Message sharing | A parent-scoped message facet withholds siblings and parent administration. Returned files, search, previews, and subscriptions preserve its limits. |
| Provenance | Source and explicit issuance context survive resharing within their declared lifetime. Limited inspectors cannot traverse to privileged ancestors. Raw forwarding is not counted as a new managed share. |
| Cross-owner effects | An upstream refusal remains effective through mediators. Partitioned mutation requests cannot report a commit; independent references on the same connection remain usable. |
| Reorganization | Rename, split, merge, and move scenarios follow the chosen identity and audience contract, including existing message grants and notification recipients. |
| Crate boundaries | The portable model builds without Rooms, binding, or platform imports and serves a non-chat fixture. Hosting integration uses existing actors and Host APIs; Rust consumes the shared Zig model. Rooms content does not duplicate grant state or lifecycle decisions. |
