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
records that split. General graph editing and privileged owner lifecycle are
outside this profile.

## Setting up

Link `libglowcap_loam` beside the existing Host archives. Add
`libglowcap_loam_lmdb` for LMDB storage. Rust enables the `loam` feature and uses
`loam::{Store, Schema, Limits, Policy, Registration, Content}` with the existing
`Host`, `Ref` and Session. Opening, fresh creation and privileged restoration
perform blocking startup I/O; complete them before admitting traffic. Execute
Host work on a Tokio `LocalSet`; LMDB jobs run on its blocking executor.
The [browser profile](browser.md) uses the same resource model with asynchronous
IndexedDB opening, creation and restoration.

In Rust, the LMDB path is four calls before traffic starts:

```rust
let store = Store::open(path, identity, true, map_bytes, &[schema], limits)?;
let resource = store.create_resource(&policy, schema, kind, initial, 2)?;
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
   request individual permissions. Create the resource before attaching. Save its returned
   `Resource::encode()` metadata only after successful commit. If creation
   reports `RECOVERY_REQUIRED`, retain the Store and call `recover_creation`;
   proven absence returns `UNCHANGED`, while committed recovery returns the
   original result. Serialized resource names are trusted local metadata.
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
   `ControlPowers` names the editing ceiling and independent pause/resume/revoke
   powers; its default grants none of them. `derive-managed` returns a list of
   two ordinary Refs: use and child control. A policy value's
   `set_policy_arguments(sequence)` supplies a `mutate` request on that control.
   A grant's configured policy remains bounded by its issuance ceiling;
   ancestor edits restrict effective use without rewriting the child's choices.
   Editing a paused grant preserves its paused status.
6. Narrow management with `ControlPowers::attenuation_arguments(sequence)` in
   a `mutate` call. `revoke-control` retires that control and its dependent
   controls while leaving use and independent controls intact. `revoke` instead
   retires the grant and its descendants. Replay the original managed derivation
   through a held source to recover the child pair after restart or a lost reply.
   A revoked grant cannot be resurrected by receipt replay. Child controls have
   no separate durable name in this profile.
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
`[policy triple or Void, lifecycle mask]`; mask bits 1, 2 and 4 request pause,
resume and revoke. Void omits policy-edit authority.

| Held endpoint method | Arguments after method name |
| --- | --- |
| `derive` | Sequence, policy triple's three fields, delegation depth |
| `derive-managed` | The `derive` arguments followed by one management selection |
| `mutate` for `set-policy` | Sequence, `"set-policy"`, policy triple's three fields |
| `mutate` for `attenuate-control` | Sequence, `"attenuate-control"`, management selection |

Depth, ceilings, policy identity and powers are admitted in Zig. Labels,
control-owned issuance, branch inventory and application-specific management
interfaces remain outside this fixed-resource vocabulary.

## Reference fields

Content may declare `ReferenceRequest::Restore(index)` or `Save { reference, uri }`
through `Content::references`. Zig prepares these requests after current grant
admission and before invocation. Same-attachment held references need no URI;
foreign references need an established sturdy URI that restores the exact held
authority. Unsupported live references and unsupported receipt capability kinds
refuse before persistent staging. Cross-attachment local scope registration is
not projected by this profile.

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
admits at most 514 requests, each URI at most 4096 bytes; shared Host quotas
bound preparation and enlivenment.

## Callbacks, memory, and limits in C

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
refuse decoding: explicitly create a new store with a fresh identity and reissue
authority; neither reopening nor application imports migrate the old grants.

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
