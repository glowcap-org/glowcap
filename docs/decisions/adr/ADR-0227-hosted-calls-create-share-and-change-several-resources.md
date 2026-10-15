---
id: ADR-0227
status: accepted
date: 2026-10-14
tags: [loam, access, actors, persistence]
decision: "A managed content call can create one child of its bound resource, a share names an object or subtree scope, a subtree grant's observer hears changes below its target, a dependent facet can derive a grant scoped to its target, and one call can change the content of up to two more resources of the same owner, each admitted by every grant the call carries and committed in one owner batch."
supersedes: []
superseded_by: []
amends: [ADR-0169, ADR-0173]
amended_by: []
---

# ADR-0227 Hosted calls create, share, and change several resources

## Context

ADR-0169 binds one hosted content call to one fixed resource: its content,
its reference fields, and an optional structural change to that same
resource. ADR-0173 lets a container return a dependent facet for a stored
child, admitted by the invoking grant and the child's own grant. The storage
layer below already composes several managed changes of one owner in one
batch, and the owner's change history records each one.

A tree application needs three things the hosted layer does not offer. Adding
a task to a list creates a resource. Sharing one task a listing returned
issues a grant at that task, but a dependent facet refuses `derive`. Moving a
task changes the task's placement and the content of both lists, which is
three resources in one call. Without these, an application either drops
per-node sharing or writes its own transaction runner above the hosted layer,
which is the second state machine the architecture rules forbid. Rooms needs
the same three for child conversations, message moves, and splits.

## Decision

**Creation.** `ContentBehavior.create` declares, before invocation, the kind of
one child to create under the bound resource. The invoking grant admits the
method's requirement at the bound resource, and the owner policy admits the
kind under the parent. The callback supplies the child's first payload through
`ContentCall.createChild`. The batch appends the resource, writes its content
record, stages a use endpoint bound to the owner's child descriptor, and
appends a strong field naming that endpoint to the bound content. The child's
one home is that field, so a listing reaches it like any other stored child.
The call replies with the child itself, as a facet of the invoking endpoint
like the one `discloseDependent` returns, and its receipt replays that same
facet. A caller never finds what it made by position, which another caller's
change could shift. Because the reply is a capability, a caller on the same
Host receives it through an owning Host call.
`Service.child_descriptor` names the descriptor each owner's stored children
use. A creating method must be receipt-backed.

**Sharing a listed node.** `derive` and `derive-managed` through a dependent
facet issue under the invoking grant, scoped to the facet's target, and the new
endpoint binds the target's content. The target grant must be active. Receipts
stay on the invoking endpoint, and replay compares the target binding.

**Sharing a branch.** The shared vocabulary names a share's scope explicitly,
as the symbol `object` for the named resource alone or `subtree` for it and
every descendant, including ones added later. A tree application shares a
whole board or one list with its tasks this way. The core already admits both
scopes and the policy's kind rules bound what each carries, so the vocabulary
carries the caller's choice instead of fixing one.

**Watching a branch.** Observation of a use whose own grant covers the target's
subtree reports a `subtree` notice when a descendant's content changes or a
child is created, moved, or deleted below the target, and the target's subtree
stamp joins that context's cursor digest. The stamps already advance along
every changed path, so this costs no new write. A grant scoped to the target
alone keeps its cursor and notices unchanged, so watching never discloses more
than the grant could read.

**Several resources.** `ContentBehavior.participants` declares up to two more
resources a call touches, each named by a strong field of the bound content or
by a capability argument that designates a same-owner endpoint or dependent
facet on this attachment. Designation only names the resource. Every grant the
call carries admits the participant's declared requirement at it. The
structural effect (`ContentBehavior.resource`) may target a participant and
may move it under another participant. Each loaded participant reports the
bound content's first strong field that stores its endpoint, if any, so a
method can name a listed node by the capability a caller holds instead of by a
position another change may shift. `ContentCall.participant(i)` offers the
same content and field edits as the bound content. All effects stage through
the call's one staging operation, which is the target's operation for a call on
a dependent facet and the invoking operation otherwise. The batch submits one
header and one change-history batch whose effects name every resource touched.
That batch is the operation journal, and no second journal exists.

**Receipts and replay.** A receipt records a dependent facet argument by the
endpoint it designates. That record names the intent and never restores
authority, so a reply cannot return it. Participants and effects resolve only
for a fresh sequence. A replay answers from its receipt without reading
current content, so a retry after the move committed still matches.

## Scope

Participants belong to the bound resource's owner. A change that spans owners
stays two acknowledged acts. A call creates at most one child and does not
combine creation with a structural move. Content graphs (ADR-0198) take no
participants. A participant cannot be the bound resource or repeat another.

## Alternatives considered

- **Create children only from the trusted embedding.** Rejected because every
  tree application would then route peer requests through an unadmitted side
  channel or a second transaction runner.
- **Bind a created child's stored endpoint to the creator's grant.** Rejected
  because revoking the creator would hide the child from everyone who lists the
  parent. The owner's child descriptor keeps the stored field independent of
  who created it, and the dependent facet still applies the reader's grant.
- **Name participants by resource identifier.** Rejected because the call must
  also find the participant's content, which only an endpoint binds, and an
  identifier from a peer names nothing the peer was shown.
- **Admit each participant through the designating capability alone.**
  Rejected because a move would then mix authorities. One rule, every grant the
  call carries at every resource it touches, keeps admission reviewable.
- **A general transaction object exposed to callbacks.** Rejected because
  callbacks would gain an open-ended effect set. A declared, bounded
  participant list keeps preparation, budgets and receipts fixed before
  invocation.

## Consequences

`src/loam/access/hosting/participants.zig` resolves, admits and loads
participants, and `src/loam/access/hosting/creation.zig` holds the declared
child from its prepared append to the facet the call replies with.
`src/loam/access/hosting/working.zig` prepares both beside the bound content,
and `src/loam/access/hosting/commit.zig` stages every effect through the one
staging operation. The storage operation
(`src/loam/access/storage/capability_operation.zig`) gains a child append, a
structural admission check another operation can run, and extra content paths
beside its one structural or grant effect. `Attachment.designated` and
`Vat.stateAs` let the attachment recognize its own dependent facets.
`ContentInvocation` exposes loaded participants to the resource, create and
invoke callbacks. `src/loam/access/storage/observation.zig` and
`observation_snapshot.zig` derive the `subtree` notice and digest.

## Evidence and verification

`test/loam/access/tree_hosted_test.zig` creates children at the root and
through a dependent facet, replays a creation, moves a node between two others
in one revision, changes two content records together, and checks that each
committed change batch names every touched resource. It also proves a refused
move leaves every record and the sequence unchanged, a stray field refuses,
a share of a listed node reads but cannot post, and an out-of-scope participant
refuses before invocation. Its observation case shows a subtree grant's watcher
hears a grandchild added while an object share's cursor stays put. `test/loam/engines/tree_crash_test.zig` loses or
commits a move's write, reopens LMDB to all of it or none of it, and retries
the same intent through fresh facets exactly once.
