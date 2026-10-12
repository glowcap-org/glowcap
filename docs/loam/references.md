# Stored capability fields

An actor's saved state can hold capabilities. Durable fields restore through
a local record, another attachment, or a sturdyref on another Host. Live fields
retain exact authority until their hosting lifetime ends.

| Term | Meaning here |
| --- | --- |
| attachment | The connection between one store and a Host: it wakes actors when calls arrive and saves their state before replying. |
| recipe | A small record selecting a local record, another attachment, a sturdyref, or exact custody in the current live lifetime. |
| scope | A registry that lets several attachments on one Host and store name each other. |
| custody | A retain the library holds on your behalf while an operation is in flight, released when it finishes or is cancelled. |
| disclosure | Handing saved authority to a caller in a reply. A managed reply must declare what it discloses. |

`glowcap.loam.hosting.references` saves authority the application
holds. It supports direct same-attachment edges, dependencies on another
attachment in the same Host/Store, and established sturdy references to another
Host/Vat. It stores no session export positions, pointers, or inferred grant
identities. [ADR-0182](../decisions/adr/ADR-0182-held-authority-reference-recipes.md)
owns this contract.

Register `hosting.references.schema` with the Store when using recipe fields.
A strong edge with `restoration = .recipe` points to a bounded recipe record.
Ordinary edges default to `.object`. The portable collector follows both and
does no networking. A local recipe retains its actual target. A foreign recipe
retains its URI locally. The remote publication owner keeps its own target
alive. Removing a field cannot retire another peer's publication.

Record envelope version 2 stores one extra boolean per edge. Metadata format 3
requires that profile and the atomic name index, and older stores need
recreating.

## Saving held authority

Call `references.beginSave(attachment, allocator, capability, uri)` at a
top-level Host boundary. The returned opaque `Save` owns one capability retain
and any pending Host enlivenment. `result()` reports `pending`, `ready`, or
`failed`. Deinitialize it before closing its attachment. Attachment destruction
refuses live saves. Cancellation releases custody and does not undo an already
admitted remote operation.

Same-attachment targets save immediately through `Attachment.capture`. For
another attachment on the same Host and Store, create a bounded
`references.Scope` and pass it with a stable borrowed `attachment_name` to each
attachment's options. Names must be unique, nonempty, and at most 128 bytes.
The scope refuses another Host or Store and cannot close while owners remain
registered. Attachments on one Host share its Vat. Separate Hosts use the
foreign path even when they run in the same process.

A foreign save requires an already established sturdy URI. Host enlivens it and
checks canonical capability identity against the held capability. A name for a
different use or control role fails with `DurableReferenceMismatch` before any
content write. Readiness proves identity and promises neither remote availability nor
permission. URI input and canonical output are limited to
`references.max_uri_bytes`, 4096 bytes.
Live-only targets without a durable recipe fail with `NotDurable`. Foreign
fields require object references on both save and restoration. Resolve a
promise to its object before saving. Promise references refuse with
`NotDurable` before a save starts network work.

Obtain or publish the durable reference before the local transaction. Saving
publishes no target remotely and creates no distributed transaction. Store
access and publication names are privileged embedding interfaces, and remote
callers enter through held capabilities.

## Live fields

For authority that ends at restart, declare `.save_live = held` and configure
a bounded `hosting.LiveScope`. Its runtime table retains the exact capability
under the committed recipe identity. The stored recipe contains an epoch and
one strong epoch edge. It contains no runtime handle and cannot reconstruct
authority after restart. Register `hosting.LiveEpoch.schema` alongside the
reference schema when configuring a Zig Store.

`LiveScope.startHosted` starts a fresh or advanced epoch on an existing
attachment. Drive ordinary attachment work through confirmed commit or exact
recovery before admitting live fields. The C `glowcap_loam_live_start` and Rust
`Attachment.start_live` expose the same path. Their schema inventory includes
the epoch automatically. The marker returned by `live_marker` is descriptive
trusted startup metadata. A new hosting lifetime must advance it even when
the Store remains open.

Warm lookup checks the current epoch and actual recipe custody. New scopes
refuse old fields with `LiveReferenceExpired`. Reservations precede waits.
Unknown writes preserve them, confirmed absence releases them, and confirmed
commit preserves custody even if reply delivery refuses. Bounded maintenance
releases custody when collection removes the last recipe occurrence.
Closing a quiescent scope releases its runtime inventory.
[ADR-0204](../decisions/adr/ADR-0204-live-recipes-retain-exact-runtime-custody.md)
owns this contract. Ordinary durable saves still refuse unsupported live targets.

## Preparing and editing fields

A managed `ContentBehavior.references` callback declares the prerequisites for
its method. It returns `references.Request` entries:

- `.restore = field_index` prepares one existing strong field.
- `.save = .{ .capability = held, .uri = established_uri }` validates a proposed
  replacement. Omit the URI for a supported local target.
- `.save_live = held` reserves exact authority for this hosting lifetime.

The declaration is pure. Preparation runs after current grant admission and
before `invoke`, using the attachment's read lane and Host networking.
All declared save targets are retained before the first request can wait.
Preparation reset or cancellation releases unstarted declarations.
A missing local restoration owner parks the call. An unavailable foreign target
fails through Host. An intervening Store commit retires preparation at a
top-level boundary and rebuilds it against current authority. Local methods
that declare no foreign field continue offline.

In `invoke`, `ContentCall.appendReference` adds a field and `replaceReference`
replaces a committed field using the prepared save, while
`replaceSavedReference` accepts a ready embedding-owned `Save` begun on that
call's attachment and copies its validated proof into call custody. A save from
another attachment fails with `ForeignAttachment`, even within the same Store.
`removeReference` drops a strong field. Indices address the committed fields.
Appended fields follow surviving fields. Schema edge limits admit appends before
capture. Read-only methods refuse payload or field changes. Recipe records,
field edges and payload changes stage in the same Store batch. Aborted or
uncommitted batches install none of them. Each recipe replacement creates one
record. Tracing reclaims replaced recipes after outstanding custody retires.
Repeated logical replacements need the same collection and storage headroom as
other record edits.

Generic hosted behaviors can use `references.Set` inside their existing
`Preparation`. The Set belongs to its `hosting.Call`. Emit its reads through
that preparation, route completions to `completeRead`, and let call cleanup
retire it. Restore direct edges lazily. Recipe edges require a declared,
completed Set before `Call.storedEdge` can restore them. Restoration and capture
only retain custody. Managed replies require an explicit disclosure declaration.

## Disclosure and dependent calls

`discloseExact` hands over the saved authority, including its original, use,
or control role. `discloseDependent` returns a runtime facet retaining the
invoking endpoint and exact target. It declares only the facet for the reply.
Capturing or saving the underlying target cannot authorize its disclosure.
Same-attachment targets in one authority domain use the shared
managed evaluator. Independent owners, including those sharing an attachment,
require the source content behavior's pure
`dependent_requirement` callback for each forwarded method. The source checks
that requirement before dispatch. The target checks its own authority through
normal delivery. Source revocation does not recall an effect already dispatched.

`save_live_dependent` prepares and reserves one facet over an actual source and
target before waits. `preparedLiveDependent` borrows only the matching declared
facet for staging. It grants no disclosure. Saving that facet once makes exact
receipt disclosure and replay return the same authority. On settlement retry,
`matchesLiveDependent` checks the saved facet's actual guarded pair without
constructing another facet. Cold restoration still refuses
([ADR-0205](../decisions/adr/ADR-0205-stable-dependent-live-results.md)).

Forwarding dispatches once through Host and Vat delivery. Later Store changes
cannot replay the target effect. Its owned reply preserves nested capabilities
and target failure text through ordinary resolver settlement. Wire replies
transfer foreign occurrences through Node's handoff staging. Local deferred
replies retire temporary export names after listeners acquire their canonical
retains. A listener that publishes an occurrence gives that export its Port
binding until session retirement.

Local Vat calls retain their data-only argument/result boundary. Use
Host Value delivery for owning capability values. Receipt intent and result
codecs accept same-attachment durable capabilities. Other capability kinds
refuse before content writes. Unresolved promises, subscriptions, timers and
operating-system handles have no durable field representation.

## Bounds and evidence

Attachment options bound live saves (`max_reference_saves`, default 64) and
forwarded reply storage (`forward_reply_bytes`, default 16 KiB). Reference slots,
recipe copies and forwarding results use the fixed call arena. Scope
registration allocates one fixed owner array. A recipe has at most one local
edge and 4097 payload bytes. Store read buffers, retention slots and Host
enliven/dial budgets remain separate owners.

`Host.callCapability(allocator, session, target, verb, values, reply_bytes)`
returns an opaque `Host.Call` with bounded owned result storage. Results borrow
that operation. Keep it through projection or acquire separate retains. Call
`deinit` at top-level before destroying Host. Pending cancellation detaches the
exact observer without allocation. The operation never consumes the public
action FIFO. Unresolved targets refuse before dispatch.

[Portable reference tests](../../test/loam/hosting/reference_test.zig) cover
reverse local startup, cold Store reopen, collection during restoration,
removal, allocation refusal and save quotas.
[Managed tests](../../test/loam/access/reference_test.zig) cover exact foreign
identity, both dependent grant checks, nested replies and transactional refusal.
[LMDB tests](../../test/loam/lmdb/reference_test.zig) compact both stores,
restore the source first, exercise unavailable and revoked targets, and preserve
original/use/control distinctions. The nine-case
[process proof](../../test/loam_references_crash.zig) kills each role's field
write before commit, after commit, and after installation before reply.
These are Linux process-loss proofs. macOS execution and hardware power loss
remain separate evidence.
