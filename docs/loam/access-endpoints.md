---
type: static
description: How to host managed use and control endpoints on a Loam Host, and what each hosted method allows.
audience: human
sources:
  - resource: /src/loam/access/hosting/
---

# Managed endpoints on the Host

This guide serves managed use and control references as CapTP endpoints. The
[managed access guide](access.md) covers resources, held references, and
retries.

`access.hosting.Service` borrows a `Capabilities` value and a table of
`ContentBehavior` descriptions. Add every entry from its `behaviors()` array
to the `hosting.Attachment` behavior table.

- The Service, `Capabilities`, and behavior tables must stay at the same
  addresses until `Attachment.destroy` succeeds. If teardown reports `Busy`,
  pending work is still alive, so your callback contexts must stay alive and
  the behavior descriptions unchanged until it succeeds.
- The Service creates no Host, Vat, worker, or storage queue.

### Creating and restoring endpoints

Your program loads a current owner `Read`, including its
`prepareIdentities(count)` paths, and then calls `stageEndpoint(read, ...)`
in a Store batch. Load the committed grant before opening that batch.

- A use endpoint keeps its use grant and ties one resource to one content
  record. A control endpoint keeps only its control grant.
- That tie is your program's decision, so make sure the right resource goes
  with the right content. Method arguments cannot change it.
- Deriving a share updates the endpoint's receipts and keeps its access and
  its content.

After the commit, restore the endpoint from a checked lease.
`stagePublication(store, endpoint_lease, entropy)` gives it one durable name,
which you also restore after the commit. Grants and endpoints join their
owner's list, without keeping the owner alive, in the transaction that
creates them.

### Serving a use call

Before a call runs, Loam loads the grant, the content, and the current managed
records. The content's schema picks one `ContentBehavior` for the call.

- Its `context` is passed to every callback: requirement, retry,
  participants, resource, create, references, dependent requirement, and
  invoke.
- The Service's own decoders get `Service.context`, and entropy has its own
  callback and context.
- Replacing `Service.contents` or `Service.entropy` affects later calls and
  calls that prepare again after a commit. Old contexts and anything borrowed
  from them stay valid until each call finishes. Keep the rest of the Service
  configuration unchanged while calls are waiting.

The `requirement` callback, which has no side effects, declares the
permissions the call needs and every committed fact it depends on.
`ContentInvocation` pairs the chosen content with the resource's identity,
kind, object, and owner revision. A local dependent call describes its
target, and a forwarded call describes only the source passing it on.

One copy of this context survives storage waits and is rebuilt when a newer
commit makes the call prepare again
([ADR-0198](../decisions/adr/ADR-0198-trusted-content-callback-context.md)).
Its bytes count against the call's memory, and a call over its limit is
refused before it runs.

`invoke` runs on the Vat only after the endpoint's grant allows the
requirement. Its `ContentCall` offers these effects:

- `replace` proposes a new content payload, keeping its edges.
- `replaceReference` and `removeReference` change a declared strong field in
  the same transaction.
- `discloseExact` hands over the capability a strong edge saved.
- `discloseDependent` returns a facet that checks both the caller's grant and
  the target's grant on every call.

A capability the method did not declare is refused before the reply goes out.
[ADR-0172](../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)
defines exact disclosure, and
[ADR-0173](../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)
defines dependent disclosure and field edits. The
[stored capability field guide](references.md) covers local and remote
references, `ContentBehavior.references`, saves your program starts, rules for
forwarded calls, and which receipt capabilities are unsupported.

### Calls that change several resources

A tree application creates nodes, shares the ones a reader lists, and moves a
node between two others. Each of these is one hosted call that commits one
batch for the owner, so a crash leaves all of it or none of it, and the
owner's history names every resource the call touched
([ADR-0227](../decisions/adr/ADR-0227-hosted-calls-create-share-and-change-several-resources.md)).

- **Create a child.** `ContentBehavior.create` declares the kind and schema of
  a child under the call's resource, and `ContentCall.createChild` gives its
  first payload. The call stores the child's endpoint under the owner's
  `Service.child_descriptor` and adds one strong field naming it to the
  resource's content. The method must be backed by a receipt and return
  `.void`, and the reply is the new child as a facet of the endpoint that was
  called. A caller on the same Host receives it through a Host call that owns
  its values, and `InvocationBounds.creates` sizes the call for it. Readers
  reach the child later through `discloseDependent` on that field.
- **Change other resources.** `ContentBehavior.participants` names up to
  `max_participants` more resources of the same owner, each through a strong
  field of the content or a capability argument. Every grant the call carries
  must allow each one, under its own requirement, before `invoke` runs. A
  participant's `field` is the content field that stores it, so a method can
  move a node named by its capability instead of by a position another change
  may have shifted. `ContentCall.participant` edits a participant's payload
  and fields like the call's own content. `ContentBehavior.resource` may move
  or delete a participant as well as the call's own resource.
- **Share a listed node.** `derive` and `derive-managed` on a dependent facet
  issue a grant for the facet's target under the caller's grant. The receipt
  stays on the endpoint that was called, which owns the derivation sequence.
  A `subtree` scope shares the node and everything below it, and `object`
  shares the node alone.

A capability argument only names a resource and allows nothing. Permission
always comes from the call's own grants.

The attachment commits the content before it sends the reply. Callbacks are
trusted Zig code with no outside effects that gives the same result for the
same input, and the API does not sandbox them.

### Control endpoints

Control endpoints accept `pause`, `resume`, and `revoke` with no arguments.
Each replies true when it committed a change and false when nothing changed.
A revoke writes one record that every later use checks, so it takes effect
at once and costs the same however far the grant was shared. Durable names
in the revoked branch keep resolving, and calls through them fail as revoked,
until [owner cleanup](access.md#bounded-owner-cleanup) retires them.

An optional `decode_control` callback turns application methods into
`core.Control.Edit` values, including policy edits.

- It only decodes. The control's stored powers and the shared rules decide
  whether an edit is allowed.
- It runs after the control's reads and receives the loaded
  `Control.Powers`. Their policy limit gives the scope for application policy
  edits, and the terms it returns may borrow that scope until the call
  finishes.
- An edit that changes something writes the grant, the owner's revision, and
  a history entry in the attachment's transaction.
- Pause, resume, and revoke are safe to repeat, and the
  [receipt form](access.md#retrying-mutations) returns the first result after
  a lost reply.

### Failure, recovery, and limits

A call owns its preparation and leases. Any Store commit that lands first
makes the call prepare again, even if it is already queued to run. Reads in
flight complete before their buffers or state are freed. An unknown write
keeps the store refusing work, and no affected call replies with success
until recovery decides. A near call to a managed endpoint in memory returns
`DurableTurnRequired`, so use eventual calls.

Budget the endpoint and content leases on top of the managed operation's
grant, header, model records, and one directory page read along the way.

- `record_capacity` bounds the records one operation holds, and the
  `Capabilities` quotas bound how many operations can run at once.
- These come on top of the attachment's call memory and share the Store's
  cache and lease limits.
- A finished call releases everything its operation held, and content and
  permission records can then leave the cache like any other.

`hosting.Behavior.prepare` sends read work through the same attachment, and
`Call.transaction` adds a trusted participant to the call's batch.
Participants only add changes, and the attachment begins and commits the
transaction. Managed hosting uses these hooks for content, structural,
control, sharing, and [observation](access.md#observing-held-access) calls.
[ADR-0169](../decisions/adr/ADR-0169-managed-host-turns.md) records the
design.
