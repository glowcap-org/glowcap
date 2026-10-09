# C and Rust resource lifecycle

This guide is for C and Rust programs that use Loam's managed resources
without writing Zig. It covers one profile: a fixed resource, such as one
shared board, that you create, share, edit, and keep across a restart. In the
terms of the [Loam guide](../loam.md):

- **Create** the resource and the content record behind it.
- **Share** it by deriving a *facet*: a narrower capability for one grant,
  handed to a peer as an ordinary `Ref`. A separate *control* capability can
  later pause, resume, or revoke that grant.
- **Edit** the content and its access policy, including the references the
  content holds.
- **Restart** and *cold-fetch*: reopen the store, and a peer fetches the same
  durable name to reach the content again, with nothing loaded at startup.

Zig still owns policy, grant ancestry, transaction order, and receipt replay.
C and Rust supply the content's code and carry out the storage work. The
[boundary decision](../decisions/adr/ADR-0185-loam-c-and-rust-resource-lifecycle.md)
records that split. Registered content pages can form a bounded graph behind
one resource. General resource-graph editing and privileged owner lifecycle
are outside this profile.

## Setting up

Link `libglowcap_loam` beside the existing Host archives. Add
`libglowcap_loam_lmdb` for LMDB storage. Rust enables the `loam` feature and uses
`loam::{Store, Schema, Limits, Policy, Registration, Content}` with the existing
`Host`, `Ref` and Session. Opening, fresh creation and privileged restoration
perform blocking startup I/O; complete them before admitting traffic. Execute
Host work on a Tokio `LocalSet`; LMDB jobs run on its blocking executor.
The [browser profile](browser.md) uses the same resource model with asynchronous
IndexedDB opening, creation and restoration.

In Rust, prepare the resource before committing its private startup metadata.
The embedding supplies `persist_private_resource` below:

```rust
let store = Store::open(path, identity, true, map_bytes, &[schema], limits)?;
let staged = store.stage_resource(&policy, schema, kind, initial, 2, owner_identity)?;
persist_private_resource(staged.resource().encode())?;
let resource = staged.commit()?;
let attachment = store.attach(&host, registrations)?;
let (access, control) = attachment.restore(resource)?;
```

## The lifecycle, step by step

1. Open an existing directory with a stable 16-byte store identity and bounded
   application schemas. Rust's LMDB `Store::open` also requires `map_bytes`
   (at least 1 MiB), a physical storage budget independent of resident and staged
   record bytes in `Limits`. Storage capacity refusal leaves the transaction
   unchanged; close and reopen with a larger map when the embedding chooses.
   Creation refuses an existing store; reopen refuses a
   missing or mismatched one. Exclusive custody prevents concurrent writers.
2. Define a policy with sorted distinct permission keys and lower/upper-bound
   constraints. `Policy::with_dependencies` also accepts `(permission,
   prerequisite)` key pairs. Configured terms and editing ceilings must include
   every prerequisite; refusal never adds authority. Method requirements can
   request individual permissions. Stage the resource before attaching, persist
   its provisional `Resource::encode()` metadata, then commit the staging guard.
   Dropping or aborting an unsubmitted guard discards staging. These names cannot
   restore authority until their records commit. Aborted names are never reused.
   `create_resource` combines preparation and commit when separate anchor
   persistence is unnecessary. If creation
   reports `RECOVERY_REQUIRED`, retain the Store and call `recover_creation`;
   proven absence returns `UNCHANGED`, while committed recovery returns the
   original result. Serialized resource names are trusted local metadata.
   `Store::open_bootstrap` projects the shared atomic bootstrap mode when the
   embedding has persisted its store identity before opening.
3. Register content implementations by schema/version. Each method declares
   `ReadOnly`, `Idempotent` or `Receipt` retry behavior. Requirements supply
   permission keys and content facts; the Zig evaluator admits the operation.
   `Content::invoke` returns a passable value and may call `Call::replace`.
   `loam::refusal(message)` constructs a deliberate callback refusal. Its local
   detail is application-owned; the peer receives `ApplicationRefused`. Caught
   Rust callback panics also refuse the call and retain their diagnostic in
   the Host's bounded failure journal, claimed with `Host::take_failures`.
   Receipt methods use the existing `mutate(sequence, verb, args...)` envelope.
4. Attach to the application's Host, restore the use/control pair and share
   ordinary `Ref` values. `Policy::value(...).derive_arguments(sequence, depth)`
   supplies the first profile's bounded derivation vocabulary. The held endpoint
   supplies resource scope and checks ceilings and delegation. Preserve the
   Host seed and the returned durable name to cold-fetch a derived facet after
   restart. Policy keys and object IDs alone confer no invocation authority.
5. Request a managed child with `managed_derive_arguments(sequence, depth, powers)`.
   `ControlPowers` names independent Inspect, Issue, Edit, DelegateControl and
   pause/resume/revoke powers; its default grants none of them. `derive-managed` returns a list of
   two ordinary Refs: use and child control. A policy value's
   `set_policy_arguments(sequence, revision)` supplies a `mutate` request on that control.
   Read the expected grant revision with `control_revision(&host, &control)`.
   A grant's configured policy remains bounded by its issuance ceiling;
   ancestor edits restrict effective use without rewriting the child's choices.
   Editing a paused grant preserves its paused status.
6. Narrow management with `ControlPowers::attenuation_arguments(sequence)` in
   a `mutate` call. `revoke-control` retires that control and its dependent
   controls while leaving use and independent controls intact. `revoke` instead
   retires the grant and its descendants. Replay the original managed derivation
   through a held source to recover the child pair after restart or a lost reply.
   A revoked grant cannot be resurrected by receipt replay. Issued and narrowed
   controls answer `durable-name` with their own independent publication secret.
   Save or share that name at the control's actual hosting peer; a use name
   cannot reconstruct it. Private bootstrap controls remain unpublished.
7. Close sessions, then close the attachment and Store. Host shutdown also
   detaches quiescent registrations before releasing its C owner. Callback
   contexts drop only after successful detach. Closed wrappers cannot invoke
   the freed attachment; Store release refuses outstanding borrows. Dropping a
   LMDB progress observer waits for worker retirement, which can block its thread.

## Sharing and managing access from C

The [held-scope decision](../decisions/adr/ADR-0187-held-scope-management-vocabulary.md)
owns the neutral management vocabulary. C embedders send the same ordinary
Host arguments; these operations do not add C entry points. A policy triple is
`[identity bytes (16), [permission mask bytes (8)], ordered bounds]`, with each
bound either Void or eight unsigned big-endian bytes. A management selection is
`[Edit policy triple or Void, Issue policy triple or Void, power mask]`.
Mask bits 1, 2, 4, 8 and 16 request Pause, Resume, Revoke, Inspect and
DelegateControl. Each policy ceiling is independent. Revision arguments are
eight unsigned big-endian bytes, including when the value exceeds signed i64.

| Held endpoint method | Arguments after method name |
| --- | --- |
| `derive` | Sequence, policy triple's three fields, delegation depth |
| `derive-managed` | The `derive` arguments followed by one management selection |
| `issue-access` on control | Derivation sequence, expected revision, immutable ceiling policy triple, initial configured policy triple, depth, management selection, UTF-8 label, initially paused Boolean |
| `inventory` on control | Cursor bytes or Void, limit from 1 through 32 |
| `mutate` for `set-policy` | Mutation sequence, `"set-policy"`, expected revision, policy triple's three fields |
| `mutate` for `set-label` | Mutation sequence, `"set-label"`, expected revision, UTF-8 label |
| `mutate` for `pause`, `resume`, `revoke` | Mutation sequence, verb, expected revision |
| `mutate` for `attenuate-control` | Sequence, `"attenuate-control"`, management selection |

Depth, ceilings, policy identity and powers are admitted in Zig. Labels own at
most 120 UTF-8 bytes and carry no authority. Issue requires a held issuance
ceiling and non-revoked source ancestry; it works while use is paused, narrowed,
or unable to delegate. Child use retains the source's restrictions. Nonempty
child management additionally requires DelegateControl.

Rust's `PolicyValue::with_ceiling` constructs an `IssuePolicy` containing the
initial configured policy and immutable ceiling. Both are explicit in the
retained issuance request. Editing can later change configured use within that
ceiling; requesting management powers does not widen it implicitly.

Inventory requires Inspect and walks the held grant's direct-child index.
Each row describes slot, generation, revision, label, own status, inherited
status, ceiling policy, configured policy and delegation depth. It carries no
use/control capability or publication secret. Cursors bind endpoint identity
and Store revision. Edits invalidate them; restart paging from Void on conflict.

Issuance uses the existing derivation receipt window. Exact replay checks held
management, source ancestry and returned endpoint custody before recovering the
original pair; it does not compare the old revision as a fresh issuance. Edit
replay likewise finds its committed mutation receipt first. Fresh no-op edits
still compare expected revision. Application-specific management metadata and
Rooms application behavior remain outside this shared profile. The
[session guide](../rooms/session.md) describes its production consumers.

Rust projects management replies through borrowed `ControlDescription`,
`PolicyDescription`, `GrantDescription` and `InventoryPage` views. They preserve
unsigned revisions and typed bounds without copying labels or maintaining a
grant mirror. Inventory contains at most 32 descriptive rows; a full last page
can require a final empty page to confirm exhaustion. Row identity confers no
control authority. The Rooms `client::access::Control` uses an actual held
control, explicit expected revisions and a retained `Issuance` request for replay.
Its session trace checks independent powers, paused and narrowed issuance,
pagination, stale edits, cold restoration and descendant revocation on LMDB and
IndexedDB. Production startup and the editor still use the existing owners.

## Reference fields

Content may declare `ReferenceRequest::Restore(index)` or `Save { reference, uri }`
through `Content::references`. Zig prepares these requests after current grant
admission and before invocation. Same-attachment held references need no URI;
foreign references need an established sturdy URI that restores the exact held
authority. Unsupported live references and unsupported receipt capability kinds
refuse before persistent staging. Cross-attachment local scope registration is
not projected by this profile.

An edit using prepared restored authority can reuse a matching retained
committed recipe edge. Repeated fields using one prepared save share one immutable recipe
row in that transaction; an aborted transaction cannot lend its ID to a retry.

Graph consumers can explicitly declare `ReferenceRequest::RestorePageWithUri`
and borrow the canonical recipe URI with `Call::page_saved_uri`. Foreign URI
bytes survive through callback return; local and valid live recipes return `None`.
Expired live custody still refuses restoration. Ordinary restoration retains no URI copy or recipe row lease.
`ReferenceRequest::uri_call_size_bound` derives the additional retained-call
demand. This metadata follows exact restoration and grants no reply disclosure.

`Call::append_reference`, `replace_reference` and `remove_reference` stage fields
with payload changes in one shared transaction. Exact disclosure returns the
saved authority; dependent disclosure also mediates every call through the
current invoking grant and `Content::dependent_requirement`. Removing custody
does not revoke independently held authority. Indices address committed
application fields throughout an invocation; appended fields follow the surviving
fields. Duplicate edits refuse.

Created content keeps its managed resource through a protected first strong
edge. Application indices omit this binding, and `field_count` reports only
application fields. Schema edge limits include the binding. Old prerelease
content without it refuses invocation; explicitly recreate that store rather
than relying on a compatibility reader. The
[reference-field decision](../decisions/adr/ADR-0188-managed-content-reference-fields.md)
owns this contract.

C reference declarations borrow their token only during the synchronous
callback. URI bytes copy into the retained call arena before return. A declaration
admits both the old restored fields and new saved fields: at most twice 514
requests for a single record, or twice the graph's aggregate edge limit.
Each URI has at most `GLOWCAP_LOAM_MAX_URI_BYTES` bytes, which Rust exposes as
`ReferenceRequest::MAX_URI_BYTES`. Shared Host quotas bound preparation and
enlivenment.

## Registered content graphs

Set `Registration.graph` to a `Graph` declaring page schemas and aggregate
page, payload and edge limits. Register every schema before opening the Store.
The root's application fields become owned page links. Each page's protected
first edge binds the same canonical resource; its remaining fields retain
capabilities. Shared hosting validates those roles before invocation.

`Invocation.graph` borrows the prepared pages. Declare saved fields with
`ReferenceRequest::RestorePage`, then use `Call::page_reference` for exact
callback-bound custody or `disclose_page` for a checked result.
`replace_graph` accepts an ordered list of kept handles, payload updates and
written pages. A payload update preserves the selected page's exact committed
fields without restoring their targets. This lets a receipt settle while an
unrelated upstream authority is unavailable. The update uses this preparation's
borrowed page token, and the shared owner checks its revision and graph capacity.
Handles belong to that callback and cannot be saved as durable identities.
The setter copies replacement bytes before Rust or C buffers retire.

Written pages accept `GraphField::Held` for newly held authority and
`GraphField::Retained { page, index }` for an exact committed field in this
preparation. Retained fields preserve object/recipe identity without restoring
the target, so reorganizing or releasing local custody does not depend on an
upstream connection. Index zero selects the first capability field, never the
resource binding. Shared validation rejects foreign tokens, invalid indices
and weak fields before capturing any held capability. Page membership uses the
bounded snapshot inventory; field lookup decodes one fixed-width edge.

Preparation releases each page lease before reading another. The retained
snapshot, candidate and callback spines count against `Limits.call_bytes`,
including block headers, alignment and spare capacity. Heap blocks grow only
as needed. Admission reserves the whole call ceiling: `pending_bytes` bounds
the attachment's reservations, and `ingress_bytes` bounds one ingress after
queue dispatch. These allowances do not expand the
Vat message queue. Physical record and transaction limits remain independent;
a refusal aborts the complete graph, managed event and retry receipt.
Replaying a committed receipt rechecks current source and target authority and
the receipt's retained results. It does not prepare the current content graph
or declare new reference saves; unrelated graph availability cannot gate replay.

`record_capacity` bounds the pinned managed working set per operation; leave
two additional leases for the descriptor and directory read window.
`max_reference_saves` bounds live save proofs, including completed proofs held
through the transaction outcome. Both are checked before storage opens.
`max_retentions` separately bounds live Store roots, including each restored
recipe held through settlement. `max_references` bounds attachment endpoints;
increasing recipe custody does not require reserving more endpoint slots.
`record_bytes` bounds the complete encoded record, including its envelope and
checksum; schema payload limits apply inside that physical bound.
Before opening storage, use `Schema::encoded_size_bound` in Rust or
`glowcap_loam_schema_size_bound` in C to derive an application's complete row
bound. The shared encoder measures scalar lengths without allocating or reading
storage, and refuses arithmetic overflow. Include every row family in the
transaction profile; this query does not reserve storage or admit a schema.

`StagingBounds::content(path, receipt)` in Rust and
`glowcap_loam_content_staging_size_bound` in C derive the managed rows for one
content effect. The path includes the target and every ancestor. Its rows join
the owner, change batch and history, plus the optional mutation receipt and
invoking endpoint. `StagingBounds::references(saves)` and
`glowcap_loam_reference_staging_size_bound` derive at most one canonical recipe
row per fresh save. Reused committed fields need no new recipe. Add application
root and page rows using their schema bounds. Sum `changes` and `staging_bytes`;
take the largest `record_bytes`. These queries use the owners' registered row
families without exposing private schema identities to a consumer.

Staging bytes cover retained encoded proposals. Temporary payload rendering,
replacement encoding, Store descriptors and backend metadata have separate
costs. Creation, resource/control edits and multiple managed effects require
their own profiles. Repeated proposals for one row replace its retained bytes;
old pages and expired history entries lose edges rather than adding deletion
rows. Sizing queries neither read storage nor admit writes, and refused C
queries zero every output field.

`ReferenceRequest::call_size_bound` in Rust and
`glowcap_loam_reference_call_size_bound` in C derive the reference contribution
to `call_bytes` for one preparation and staging attempt. Supply upper bounds
for old restore occurrences, new save occurrences and supplied or stored URI
input bytes, at most `GLOWCAP_LOAM_MAX_URI_BYTES`. Canonical URI expansion, copied C declarations,
request-spine growth, recipe payloads and one temporary parse window are included,
as are block headers, alignment and growth slack. This is an additive physical
contribution. Add separately sized invocation projections, snapshots, candidates,
held fields, application callbacks and replies; it is not a complete call budget.
Rust callback buffers and Host network state have their own owners. The query
uses bounded scalar growth enumeration, allocates nothing in shared Zig and
admits no work. A refused C query leaves its output zero.

`Graph::call_size_bound` in Rust and `glowcap_loam_graph_call_size_bound` in C
derive the graph contribution for one preparation and complete replacement.
Each supplied bound covers both old and new populations: child pages exclude
the root, aggregate payload bytes include it, and capability fields exclude
resource bindings and page links. The query includes streamed child snapshots,
view and candidate inventories, C payload/field copies, both prepared callback
page projections and staged edges. The old root remains borrowed. Aggregate
bytes are charged once, with padding and block overhead per possible positive
allocation. Add reference preparation, private managed state, receipt data,
argument projections, held occurrences, application callbacks and replies
separately. Store staging and Rust callback buffers remain independently owned.
The [graph decision](../decisions/adr/ADR-0199-retained-resource-content-graphs.md)
records the ownership and cost boundary.

`InvocationBounds::call_size_bound` in Rust and
`glowcap_loam_invocation_call_size_bound` in C derive the managed-content
invocation contribution. `ValueBounds` counts every value node, struct keys
separately, aggregate copied leaf bytes and capability occurrences. Arguments
describe the complete incoming vector, including `mutate` sequence and method
wrappers. Reply bounds must cover both fresh results and persisted receipts
for the profile's lifetime. Held occurrences count application acquisitions,
including repeated field reads; receipt capture and reply custody are added
by the query. Local dependent calls include their separate input retain.

This contribution includes private managed state, retained input, held-list
growth, optional receipt encoding and replay, C argument projections, policy
output copies and owned reply conversion. Codec costs derive from shared
writer fragments and cap at accepted record limits; sizing does not guarantee
that every described value is encodable. Add the reference and graph
contributions and explicit application allocation demand to obtain this
profile's retained-call allowance. Single-record content/reference
edits, resource/control edits, sharing, observation and external forwarding
require separate profiles. Store staging, Capabilities
operations, registration, resolver settlement arenas, Rust buffers and Host
network state have independent owners. All sizing queries are pure and leave
admission with the Store and attachment.

## Callback context

Rust `Content` methods receive one borrowed `Invocation`; C receives its generated
mirror. `bound_resource` supplies canonical identity, kind, object and owner
resource revision, paired with the selected content's object and revision.
`Delivery::Local` describes the executing target, including local dependent
calls. `Delivery::Forwarding` describes only the mediating source. The separately
held capability selects the forwarding destination; its metadata is unknown here.
These values are descriptive and cannot be retained as admission.

Shared hosting loads the canonical row before declaration and rebuilds the
context on Store revision restart. The C seam verifies the protected first edge
against that row before calling application code. The shared Linux and Chromium
trace checks projected identity through exact/dependent calls and cold reopen;
Zig scenarios own selection, revision fencing and refusal. Rebuild consumers
against the generated layouts.

## Callbacks, memory, and limits in C

`max_continuations`, `continuation_bytes` and `max_continuation_targets` configure
the shared runtime's independent receipt custody. Zero continuation count
disables reservation. `forward_reply_bytes` bounds each forwarded target's
owning reply, separately from the source callback and outer observer; zero or
overflow refuses before storage opens.

Receipt callbacks can call `Call::reserve_continuation_copying` with their exact
held targets. The reservation borrows the callback; its source and target getters
return independently owned references for application receipt staging. The
returned `PendingContinuation` owns observation through commit and recovery.
`confirmed` transfers that owner once, without allocating. Proven absence returns
`UNCHANGED`; unknown commit keeps custody until recovery. Dropping the observer
does not classify a commit or cancel an admitted effect.

The confirmed `Continuation` can project a public reference that rechecks source
admission, or privately `execute` a target. `EffectExecution::completed` reports
`Ready`, `Unsent`, or `Unknown`. Only `Unsent` proves that target admission did
not occur. The execution independently owns its reply and attachment borrow,
so the continuation can be dropped immediately. Each ready observation returns
ordinary owned Rust values and reference guards. C child views expire at the
next query; returned reference occurrences require independent release.
Projection refusal preserves the ready result for retry without redispatch.

The size queries separate immutable continuation custody, C observer metadata,
source-call decoding, caller reply storage and Host dispatch metadata. Rust
String/Vec storage and Host queues retain their own budgets. These are live
executor handles; applications persist effect receipts and implement restart
recovery. The [Rooms session guide](../rooms/session.md)
describes production receipts and recovery.

Read-only content can call `Call::disclose_reads_copying` over an exact held
target. `ReadInterface` declares allowed verbs; each `ReadMethod` declares
the interface index of every returned capability occurrence in depth-first
reply order. Empty result lists forbid capability disclosure. Shared Zig
retains the original source intent, checks it before dispatch and after waits,
and recursively restricts returned capabilities. A scope preserves identity
for each exact target and interface, including repeated and recursive replies.
Trusted content must declare only read operations. Mutation callbacks refuse
this disclosure path. `ReadScopeBounds::size_bound` derives independent scope
storage; temporary C/Rust declaration spines, Host actors and ordinary call
storage retain their own owners. [ADR-0206](../decisions/adr/ADR-0206-recursive-read-interfaces-retain-source-admission.md)
owns the lifetime and retry contract.

C callbacks borrow payload, verb and argument views until return. They cannot
unwind or reenter Host driving. Reply and replacement setters copy into the
existing bounded call arena. The standalone `glowcap_loam_store_new_in` uses a Context allocator for Store
and attachment allocations; keep that Context alive through all their releases.
The LMDB companion uses the library allocator. Declarations and method names
are copied at attach;
application and entropy contexts remain borrowed until successful detach.
Policy descriptors allow at most 64 permissions and 16 unsigned bounds. Methods
are limited to 64 per registration, with names of 1–256 bytes; the profile
accepts at most 128 content registrations. `Limits` owns cache, lease, staging,
reference and operation budgets. The work pool reserves `cache_slots + 1` slots
at startup, so individual C storage effects allocate no handle.

In C, `GlowcapLoamPolicy.prerequisite_masks[i]` lists required bits in the same
sorted order as `permissions`. Unused rows must be zero; self and undeclared
bits refuse construction. The copied policy matrix occupies 512 bytes and adds
no allocation; validation visits at most 64 selected permissions. Owner records
persist the matrix within their existing 4 KiB payload limit. Rebuild consumers
against the generated header. Old prerelease owner records without the matrix
or kind list refuse decoding: explicitly create a new store with a fresh identity and reissue
authority. Reopening and application imports refuse incompatible grants.

`Policy::with_kinds` declares exact and future-subtree support for up to 16
sorted resource kinds. A nonempty table refuses unknown kinds. The factory
issues the exact kind's supported permissions; it preserves the full vocabulary.
Direct derivation, edits and control ceilings obey applicability after reopen.
`value_for_kind` prepares exact-interface terms through the shared Zig check;
it supplies data and does not admit an effect or confer resource authority.
Kind rows add 384 inline bytes plus a count, without allocation; the maximum
owner descriptor still fits 4 KiB. The
[scope decision](../decisions/adr/ADR-0197-scope-aware-permission-applicability.md)
owns mixed selections, exact effects and containment. General resource-graph operations
remain outside this fixed-resource consumer profile.

## Driving storage from C

A C embedder alternates Host driving and `glowcap_loam_advance`, takes submitted
work with `glowcap_loam_next_work`, executes it through the LMDB companion and
joins the executor. It then calls `glowcap_loam_work_complete` on the Host thread.
Its `out_completed` flag states whether completion consumed the effect even
when the status is a refusal. Zero preserves the work and all its owners. One
permits `glowcap_loam_work_release`. The caller must physically join before
completion or release; a result flag does not prove another thread has retired.
Unknown writes select recovery only after the original work is completed and
released. Failed or unstarted recovery preserves the barrier.

`glowcap_loam_advance` reports newly runnable Host work through `out_progress`,
including a fetch emitted while reference preparation still waits. Drain that
work before parking for the reply. Outstanding foreign replies and internal
work blocked on transport readiness do not keep that progress flag set.

## Evidence

`zig build loam-abi-test` proves the C ownership and recovery boundary.
`zig build loam-rust-test` proves real TCP create/share/edit/restart/cold-reopen,
narrowed admission, durable receipt replay, panic containment, callback custody
and queued worker cancellation. It shares a management trace with the Chromium
proof: bounded child controls, policy edits, ancestor restriction, control
retirement, persisted receipts and retained descendant revocation. A second
shared trace checks field authoring, exact grant preservation, dependent access,
refused replacement, removal and cold restoration. The TCP fixture is cleartext and confined to
loopback; it isolates consumer projection from transport security. Zig
Loam scenarios remain the authority for storage and grant semantics. These
LMDB checks do not establish Windows or macOS support; the
[browser guide](browser.md#bounds-and-evidence) records the browser's own proof.

The Rooms [maximum foreign trace](../../apps/rooms/rust/proofs/src/session_foreign/mod.rs)
stores two disjoint populations of 3,592 targets in 64-page graphs under composed
call and row quotas. It refuses capacity 3,661, retries at 3,662, and cold
restores every exact field after replacing the source Store and Host. Explicit
disclosure returns an owned result within the source Host; that result is not
a CapTP wire vector. Rust proof inventories and exporter actors are separate
costs. This covers maximum field/page cardinality with short URIs; maximum
URI length and the exact 1 MiB codec witness are separate checks. The C
projection witness measures the two maximum page-descriptor arrays and verifies
that payload and handle projections borrow their prepared input. It checks
logical demand before physical overhead; it does not admit a synthetic graph.
`zig build rooms-session-foreign-test` runs this case in a bounded test process.
`zig build rooms-rust-test` includes it and the remaining workspace serially,
with a separate 30-second process deadline for each run.
