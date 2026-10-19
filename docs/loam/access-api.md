---
type: static
description: The rules managed access holds for resources, scope, policy, commits, and returned references, the C ABI boundary, and the typed hosted API it does not have.
audience: human
sources:
  - resource: /src/loam/access/
  - resource: /bindings/rust/src/loam/
---

# Managed access model

Managed access lets an application keep its data as a tree of resources and
hand out narrowed, revocable access to parts of it. A grant covers part of the
tree. A use reference calls a resource, a control reference manages a grant,
and each reference held under a grant (a facet) stays within that grant. These are the rules every call keeps. The
[managed access guide](access.md) lists the Zig calls, and the
[C and Rust guide](c-and-rust.md) lists the binding calls.

## What an application gets

The application supplies the content, what each operation means, and its
policies. The [Host](../architecture.md#from-a-peer-to-an-application) turns those
decisions into local or remote capabilities. Loam stores everything and
decides what stays in memory. The Host, its Vat (where its actors run, one
message at a time), and your program's executor do the scheduling.

Three kinds of code call into it:

| Part | Caller | What it does |
| --- | --- | --- |
| Model | Application author | Defines resources, typed policies, content changes, and transactions, with no network I/O. |
| Hosting | Application host | Serves the model as capabilities, checks calls, and keeps or restores durable names. |
| Use and management | Local or remote holder | Calls a resource, inspects its own access, makes permitted shares, and controls the grants it holds. |

The model does no I/O and keeps no global list of grants. Hosting uses
glowcap's public reference and actor interfaces. Passing an ordinary reference
is an ordinary capability handoff, and managed access leaves the identities,
reference counts, and handoff tables of [CapTP](../capabilities.md#glossary),
the session protocol, alone.

## Resources and identities

An owner is one managed access domain, with its own tree, grants, and policy.
Owner, resource, and grant IDs are names you can compare and save. They carry
no authority. Authority comes only from a use or control reference you hold.

- An owned child belongs to the same owner.
- Moving owned content to a new parent is a separate change that needs its own
  permission.
- Resource IDs survive renames and restarts. A resource created again after
  it was destroyed gets a new generation.
- A display path never picks where authority comes from or rebuilds a
  capability.
- An ID, or a type label a remote peer sent, never produces a resource.

## Scope and policy

A grant's scope is one object, a bounded set of objects kept in a fixed
order, or an owned subtree. A subtree follows owned children and also covers
children added later, and the issuer is told so when the grant is made. Use a
set for a fixed group. Moving a resource can change which subtrees cover it,
so a move needs permission for both the tree change and the change in who can
see it, in the same transaction. Scope checks use the committed tree, and
moving a resource never redirects a grant for one exact object.

A policy belongs to one owner and keeps the same permission keys across
resource kinds, so a room grant can create access to one message.
[Policy and interface support](access.md#policy-and-interface-support) says
how a grant covers one object, a chosen set, and children added later.

A policy descriptor declares the permission keys, numeric constraint keys
with a lower or upper bound, which permissions need others, and what each
resource kind supports. Zig owns checking, scope containment, narrowing,
intersection, walking dependencies, and working out the access in effect.
Applications never implement those through policy callbacks.

Facts are checked resource metadata read inside the owner's current
transaction. Application hooks supply committed facts or a bounded check of
their own and cannot override the tree scope, a grant's limits, or its
status. Unknown schema values and unsupported combinations are refused.

Permissions need not all be on or off. Intersecting two bounds keeps the
stricter one, such as the shorter history limit or the smaller quota. Presets,
such as an Observer role, are values the application defines over its
policy's permissions.

The access in effect comes from the grant's own terms, the limit it was
issued with, the local grants above it as they are now, and its status. A
cached description authorizes nothing.

## Committing changes

The hosting code gets a private `Invocation` from the facet that was called.
It carries the local owner and the grant behind the call, and network input
cannot swap in another invocation by sending a resource or grant ID. A staged
change touches no committed state and hands out no capability. Its permission
result is tied to the invocation, the target, the requirements, and the tree
and policy revisions, so it cannot be reused as permission later. Application
code is trusted to declare all of its effects.

Storage runs outside the synchronous model. While a durable change is
pending, other conflicting changes to that owner return busy or wait in the
application's bounded command queue. Managed access owns no work queue.

The Loam transaction takes the storage result when it succeeds. A write whose
outcome is unknown, such as one whose confirmation was lost, stops the owner
until recovery. A write known to have changed nothing keeps the earlier
committed state. Canceling cannot release a store while it
is still writing.

The store commits content, tree, and grant changes that must happen together
as one recoverable unit. Several managed changes can join that unit. Each
one checks against the owner state the earlier ones left in the transaction,
and all of them merge into one update to the owner's header. A change
prepared against an older revision is refused, and the caller aborts with
nothing written. Two unrelated stores cannot do this, so an application uses
one shared store or its own coordinator with proven recovery. No transaction
spans two owners.

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

Receipts, the saved results of completed requests, make sharing and policy
changes safe to retry without creating extra access
([retrying mutations](access.md#retrying-mutations)). A retry with different
arguments is refused. Quotas limit
receipts, removed-record markers, tree size, nesting, child grants, pending
changes, and listing pages. A grant or owner generation is never reused to
bring back a revoked link. Error details are scoped, so a refused lookup
cannot reveal private siblings.

## Returned references

A method can return a capability its resource's content keeps in a strong
field, a declared field that keeps its reference alive.
`ContentCall.discloseExact` returns a strong field the call declared and
refuses capabilities it did not declare
([ADR-0172](../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)).
`ContentCall.discloseDependent` returns a facet that keeps both the endpoint
that was called and the stored target live
([ADR-0173](../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)).
Typed local and remote fields work through the
[stored capability field API](references.md).

A go-between on another peer holds a capability from upstream and forwards
the calls it allows. Local limits can narrow or stop forwarding, and limits
upstream stay enforced upstream. A local policy says nothing about whether
the remote side is available. A revoke reports success at the owner that
commits it, so a network split never reads as a successful remote revoke.

[Resource storage](access-storage.md) describes the managed access records.
Capability fields in content use the shared
[stored reference rules](access-storage.md#references-embedded-in-application-content),
so the payload, the exact access, and the edges that keep things alive
change together.

## C and Rust bindings

Rust uses the Zig implementation through a C ABI. The ABI converts data and
hands over ownership, and every permission decision stays in Zig.

[ADR-0185](../decisions/adr/ADR-0185-loam-c-and-rust-resource-lifecycle.md)
and the [C and Rust guide](c-and-rust.md) define what you can call.
`libglowcap_loam` owns the Store, Attachment, synchronous Call, and submitted
Work handles. The optional `libglowcap_loam_sqlite`, `libglowcap_loam_lmdb`,
and `libglowcap_loam_volatile` open storage and run the worker. Rust offers
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
and the [browser guide](browser.md) runs the same lifecycle. Rust traits give
typed views over registered schemas and build requirements for the same
model. A new general operator belongs in Zig with shared tests, and nothing
unsupported falls back to a Rust implementation.

A Goblins or Python peer can call published managed access interfaces over
OCapN without running this model or its C ABI. Those wire interfaces
need documented schemas and tests against outside peers.

## The typed hosted API

Applications call managed access through Zig's `glowcap.loam.access` and a
fixed-resource C and Rust API. A typed API with one resource type per interface
is on the [roadmap](../roadmap.md#durable-applications).
