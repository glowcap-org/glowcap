---
type: static
description: How an actor's saved state holds capabilities and how they restore after a restart.
audience: human
sources:
  - resource: /src/loam/hosting/
  - resource: /src/loam/access/hosting/
---

# Stored capability fields

An actor's saved state can hold capabilities. A durable field restores
through a local record, another attachment on the same Host, or a sturdyref on
another Host. A live field keeps its exact capability only while the current
Host runs.

| Term | Meaning here |
| --- | --- |
| attachment | The connection between one store and a Host: it wakes actors when calls arrive and saves their state before replying. |
| recipe | A small record that says how to get a reference back: a local record, another attachment, a sturdyref, or a live reference held while the current Host runs. |
| scope | A registry that lets several attachments on one Host and store name each other. |
| disclosure | Handing a saved capability to a caller in a reply. A managed reply must declare what it hands out. |

`glowcap.loam.hosting.references` saves capabilities the application holds:
edges within one attachment, references into another attachment on the same
Host and store, and established sturdyrefs to another Host. It never saves
CapTP export positions, pointers, or grant identities it would have to guess.
[ADR-0053](../decisions/adr/ADR-0053-returned-capability-authority.md)
records these rules.

Register `hosting.references.schema` with the Store to use recipe fields. A
strong edge with `restoration = .recipe` points to a small recipe record, and
ordinary edges default to `.object`. Collection follows both and never touches
the network.

- A local recipe keeps its actual target alive.
- A remote recipe keeps only its URI. The remote peer keeps its own target
  alive, so removing a field can never retire another peer's durable name.

The record format stores one extra flag per edge for this, and a store needs
the current metadata format, with its atomic name index, to use it.

## Saving a capability you hold

Call `references.beginSave(attachment, allocator, capability, uri)` from your
main loop, outside any Host processing. The `Save` it returns holds one
reference to the capability, plus any Host work still reviving a sturdyref.
`result()` reports `pending`, `ready`, or `failed`. Deinitialize it before
closing its attachment, because destroying an attachment with a save in
progress is refused. Canceling a save releases what it holds but does not
undo a remote operation already accepted.

A target in the same attachment saves at once through `Attachment.capture`.
For another attachment on the same Host and store, create a bounded
`references.Scope` and pass it, with a stable `attachment_name`, in each
attachment's options. Names must be unique, nonempty, and at most <!-- value ../../src/loam/hosting/reference_recipe.zig max_attachment_name_bytes -->128<!-- /value --> bytes.
A scope refuses an attachment on another Host or store, and cannot close
while attachments are still registered. Attachments on one Host share its
Vat. Separate Hosts use the remote path, even in the same process.

Saving a remote reference needs a sturdyref URI that already exists. The Host
revives it and checks that it names the same capability you hold.

- A name for a different role, use instead of control for example, fails
  with `DurableReferenceMismatch` before any content is written.
- `ready` means the identity matched. It does not promise the peer is
  reachable or that the capability still permits anything.
- The URI you pass and the URI Loam stores are each at most
  `references.max_uri_bytes`, <!-- value ../../src/loam/hosting/reference_recipe.zig max_uri_bytes -->4,096<!-- /value --> bytes.
- A live target with no durable recipe fails with `NotDurable`.
- A remote field must be an object reference, both when saved and when
  restored. Resolve a promise to its object first, because saving a promise
  fails with `NotDurable` before any network work starts.

Get or publish the durable reference before the local transaction. Saving
publishes nothing on the remote side and is not a distributed transaction.
Direct store access and durable names are for your trusted program, and
remote callers come in only through capabilities they hold.

## Live fields

For a capability that should end at restart, declare `.save_live = held` and
configure a bounded `hosting.LiveScope`. Its table in memory holds the exact
capability under the recipe's committed identity. The stored recipe holds
only an epoch number and one strong edge to that epoch's record. It holds no
runtime handle and cannot bring the capability back after a restart. Register
`hosting.LiveEpoch.schema` alongside the reference schema when you set up a
Zig Store.

`LiveScope.startHosted` starts a new epoch on an existing attachment. Let any
ordinary attachment work reach a confirmed commit or finish recovery before
you accept live fields. C's `glowcap_loam_live_start` and Rust's
`Attachment.start_live` do the same, and register the epoch schema for you.
The marker `live_marker` returns describes the epoch and is trusted startup
data. Each new run of the Host must move to a new epoch, even if the Store
stays open.

Looking up a live field checks the current epoch and that the scope still
holds the capability. A field from an old epoch fails with
`LiveReferenceExpired`, and an ordinary durable save still refuses a live
target.

- Loam reserves the capability before any wait. An unknown write keeps the
  reservation, a write shown never to have happened releases it, and a
  confirmed commit keeps it even if the reply cannot be delivered.
- Collection releases the capability once it removes the last recipe that
  names it.
- Closing an idle scope releases everything it holds.

[ADR-0053](../decisions/adr/ADR-0053-returned-capability-authority.md)
records these rules.

## Preparing and editing fields

A managed `ContentBehavior.references` callback declares what a method needs
before it runs. It returns `references.Request` entries:

- `.restore = field_index` loads one existing strong field.
- `.save = .{ .capability = held, .uri = established_uri }` checks a new value
  for a field. Leave out the URI for a local target.
- `.save_live = held` reserves a capability for the current run of the Host.

The callback only declares, with no side effects. Loam does the work after it
has checked the caller's grant and before `invoke`, using the attachment's
read queue and the Host's networking.

- Every capability the call will save is held before the first wait. If the
  preparation restarts or is canceled, requests that had not started are
  released.
- If a local target's attachment is missing, the call waits. If a remote
  target is unreachable, the call fails through the Host.
- If another Store commit lands first, Loam drops the preparation between
  turns and rebuilds it against current permissions.
- A local method that declares no remote field keeps working offline.

Inside `invoke`, `ContentCall.appendReference` adds a field and
`replaceReference` replaces a committed field with the prepared save.
`replaceSavedReference` takes a finished `Save` your program started on the
same attachment and copies its checked result into the call. A save from
another attachment fails with `ForeignAttachment`, even in the same store.
`removeReference` drops a strong field.

- Indices refer to the committed fields, and appended fields come after the
  fields that remain. The schema's edge limit is checked before an append
  takes anything.
- Read-only methods cannot change the payload or fields.
- Recipe records, field edges, and payload changes go in the same Store batch,
  so an aborted or uncommitted batch changes none of them.
- Each replacement writes a new recipe record. Collection frees the old one <!-- status-allow: runtime state or operation ordering -->
  once nothing still holds it, so frequent replacements need the same
  collection and disk headroom as other record edits.

Other hosted behaviors can use `references.Set` inside their `Preparation`.
The Set belongs to its `hosting.Call`: send its reads through that
preparation, pass their results to `completeRead`, and let the call's cleanup
release it.

- Direct edges restore when they are first used. Recipe edges need a declared
  and completed Set before `Call.storedEdge` can restore them.
- Restoring or saving a capability only holds it. A managed reply must still
  declare that it hands the capability out.

## Handing capabilities out

- `discloseExact` hands over the saved capability as it is, in its original,
  use, or control role.
- `discloseDependent` returns a new facet that keeps both the caller's
  endpoint and the exact target, so every call through it is checked against
  the caller's grant. It covers only the facet in this reply.
- Saving or restoring a target never permits handing it out on its own.

Targets in the same attachment under one owner use the shared managed
permission check. Separate owners, even in one attachment, need the source
content's `dependent_requirement` callback for each forwarded method, which
has no side effects. The source checks that requirement before sending the
call on, and the target checks its own permissions when the call arrives.
Revoking the source does not undo an effect already sent.

`save_live_dependent` prepares and reserves one such facet over a real source
and target before any wait. `preparedLiveDependent` borrows only that declared
facet for the transaction, and hands nothing out. Saving the facet once means
a receipt and its replays all return the same capability. When a reply is
retried, `matchesLiveDependent` checks the saved facet's source and target
without building another facet. Restoring it cold after a restart is
refused ([ADR-0053](../decisions/adr/ADR-0053-returned-capability-authority.md)).

A forwarded call is delivered once through the Host and Vat, and later Store
changes cannot run it again. Its reply keeps nested capabilities and the
target's failure text, and settles like any other promise. The Host owns how
those capabilities cross the wire or reach local listeners.

Local Vat calls pass only plain data in arguments and results. Use the
Host's value delivery for capability values the call owns. Receipt arguments
and results can hold durable capabilities from the same attachment, and other
kinds of capability are refused before any content is written. Unresolved
promises, subscriptions, timers, and OS handles cannot be saved in a field.

## Limits

Attachment options limit saves in progress (`max_reference_saves`, default
<!-- value ../../src/loam/hosting/attachment.zig max_reference_saves -->64<!-- /value -->) and forwarded reply storage (`forward_reply_bytes`, default
<!-- value ../../src/loam/hosting/attachment.zig forward_reply_bytes bytes -->16 KiB<!-- /value -->). Reference slots, recipe copies, and forwarded results use the
call's fixed memory. A scope allocates one fixed array for its attachments. A
recipe holds at most one local edge, and its payload is at most the URI limit
plus one byte. Store read buffers,
retentions, and the Host's limits for reviving and dialing sturdyrefs are
separate.

## Calling a held capability

`Host.callCapability(allocator, session, target, verb, values, reply_bytes)`
returns an opaque `Host.Call` that owns bounded storage for its result.

- Results borrow the call. Keep it while you read them, or take your own
  references.
- Call `deinit` from your main loop before destroying the Host.
- Canceling a pending call detaches its observer without allocating.
- The call never takes from the Host's public action queue, and an unresolved
  target is refused before anything is sent.

## Tests

The `reference_test.zig` files under `test/loam/hosting/`, `test/loam/access/`
and `test/loam/lmdb/` cover restoring references, managed identities and
dependent grants, and compaction on LMDB. The
[process test](../../test/loam_references_crash.zig) kills each kind of field
write before the commit, after the commit, and after the Store takes it in but
before the reply. [Stability](../stability.md) says which platforms and
failures these cover.
