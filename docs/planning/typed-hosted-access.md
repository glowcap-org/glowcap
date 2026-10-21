# Typed hosted access API

Status: active plan, waiting for maintainer review before work starts.
Delete this plan when its steps land in `dev`, the
[roadmap item](../roadmap.md#durable-applications) is removed, and the shipped
interfaces and limits are documented in the Loam guides.

## What this is for

An application should hold a typed reference to a message, call its declared
operations, share narrower access, and manage that share without assembling
wire arguments itself. C and Rust applications should also create and change
a tree of managed resources without writing Zig or rebuilding its permission
and transaction rules.

Build this on the existing Host and Loam implementation and the applications
already using it. Tasks supplies the complete board, list, and task lifecycle.
Rooms supplies managed control, inspection, observation, and retained requests
across browser interruption. Their common mechanics belong in the library.
Rooms' resource model remains a separate roadmap item.

Plain capability applications such as Tools keep using ordinary references
and wrappers when they need no durable managed resource tree.

## Where things stand

Zig already supplies durable owner creation, resource trees, grants, managed
use and control endpoints, scoped descriptions, observations, receipts, and
restoration. Hosted calls can create one child and change bounded participants
in the same owner. Their permission checks and transaction runner exist.

The C ABI and Rust binding expose a fixed-resource lifecycle and content-page
graphs. A graph of content pages is not a tree of independently shared
resources. The missing foreign operations are general resource creation,
participant changes, and the owner's lifecycle. Rust currently builds share
and control arguments for ordinary held-reference calls.

Rooms has a higher-level control client with validated owning replies,
prepared mutations, retained issuance requests, and observations. Promote its
general behavior into the library and replace its application-local
implementation. Keep Rooms' routing, membership, history, presets, and UI
projection in the application. Tasks has working Zig hosting and cross-language
clients that assemble mutation envelopes and decode replies themselves. Its
existing behavior is the baseline for typed tree calls.

The existing Rust resource value is serialized startup metadata. It is not a
held capability. The typed client must keep that distinction visible rather
than reuse that type's name in the same namespace.

The [managed access model](../loam/access-api.md) remains the authority.
[ADR-0056](../decisions/adr/ADR-0056-loam-foreign-and-browser-execution.md)
records foreign ownership and recovery.
[ADR-0052](../decisions/adr/ADR-0052-managed-owner-lifecycle.md)
records held-scope management, and
[ADR-0046](../decisions/adr/ADR-0046-resource-scopes-and-permissions.md)
records bounded tree calls. Extend these contracts where needed instead of
reintroducing mechanisms from the earlier pseudocode.

## The decision

Use typed clients over ordinary held Host references and expose missing server
operations through the shared Zig implementation. An application interface
declares its schema identity and version, call and reply types, and bounded
encoding and decoding. Adapt Tasks' existing method definitions and Rooms' generated
protocol declarations, keeping one authority for method names and limits.
Extend their existing generation where needed. No new interface language is
required.

Typed calls preserve existing method names and wire values. Promote reusable
request ownership and reply validation from Rooms, keeping its routing and
platform deadlines in the application adapter. The library owns no second
runtime or application policy catalog.

The application requirements settle the shared design:

| Application need | Shared interface | Application responsibility |
| --- | --- | --- |
| Tasks lists yield task capabilities and accept moves by held references | A resource type per interface, checked capability arguments, and typed results | Board, list, and task methods and payloads |
| Tasks adds and moves durable resources | Bounded creation and same-owner participant effects through C and Rust | Which content changes and permissions an operation requires |
| Tasks and Rooms share, inspect, edit, pause, and revoke | Typed use and control references with scoped descriptions and management | Permission keys, presets, history rules, and membership checks |
| Rooms retains an edit across interruption | An owning prepared request with the same target, sequence, revision, and input on every submission | Whether the user retries or edits a conflicting draft |
| Both restore exact access after restart | Existing durable publication, owner restoration, and recovery | Private startup metadata and when to offer a durable link |

Completion includes adopting these interfaces in Tasks and the reusable Rooms
control client. Adding a library alongside their equivalent helpers does not
complete the work. No application-specific permission or content model moves
into Loam.

The following contracts determine the work:

- A typed resource owns or retains one held reference on one Host. A typed
  control owns a separate held reference. Cloning retains the same authority
  and grant. Neither constructor accepts a resource ID or serialized startup
  metadata as authority.
- Typing checks local calls and decodes every remote reply. Wrapping an
  existing reference is an explicit application assertion about its interface,
  not proof about the peer. A wrong method, schema, version, policy, or reply
  shape produces a typed refusal without retrying through a broader method.
- Keep application method names separate from reserved management methods.
  Registration rejects collisions. A schema's request and reply bounds are
  enforced when reserving call storage and before user callbacks.
- Share the resource the reference designates. To share a listed child, use
  the held child reference. Object and owned-subtree sharing use the existing
  vocabulary. Arbitrary ID-targeted sharing and bulk selection are outside
  this plan. Unsupported scopes fail explicitly.
- Preserve separate use and control results, configured policy and immutable
  ceiling, independent management powers, and initially paused issuance.
  Use-only access cannot create a management capability.
- Keep the existing receipt sequences and revision comparisons. A typed
  mutation retains one request identity across retries. Reusing an identity
  with different input refuses. A stale revision returns a conflict without
  silently applying a fresh revision or repeating a mutation under a new ID.
- Durable references use existing publication and restoration rules. A
  publication carries exactly its use or control authority. Restarting,
  restoring, or copying cannot revive revoked access. A volatile resource
  cannot promise restoration across a process restart.
- Zig decides admission, effects, receipts, and recovery. Foreign callbacks
  declare bounded content requirements and effects. They never receive an
  unrestricted transaction or supply permission verdicts.
- Owner creation and restoration use the existing staged storage lifecycle.
  Names and references become usable only after confirmed commitment.
  Submitted work survives a dropped observer until physical retirement, and
  unknown writes block conflicting operations until recovery resolves them.
- All local and remote calls use the existing Host and executor. Zig's
  portable client exposes nonblocking completion. Rust maps that completion
  to futures on its existing Host task ownership. No new scheduler, queue,
  or binding-owned grant ledger is introduced.

The alternatives are leaving callers to assemble untyped arguments, which
repeats parsing and lifetime mistakes, or replacing the owner and transaction
model, which duplicates working authority and recovery rules. Typed clients
and a bounded foreign projection address the missing interface directly.

### Performance contract

Existing operations must be neutral or better in performance after migration.
Compare equivalent operations with the same authority, durability, payload,
and retry guarantees. A faster read does not excuse a slower mutation, and
a new feature is budgeted separately from an existing call. Typing adds no
network round trip, storage transaction, scheduler hop, or mandatory interface
probe. Preserve the existing sequence lookup where the receipt protocol needs
it. Do not cache sequences across independent writers to avoid that lookup.

Record the untyped baseline before changing the measured path. Count Host
calls, storage submissions, allocations, copied bytes, and peak retained bytes
for Tasks read, add, move, share, and watch, and Rooms inspect, policy edit,
observation, and exact retry. Separate request preparation, Host execution,
reply consumption, and teardown so savings in one do not hide new costs in
another. Keep compiler, optimize mode, workload, engine, and host fixed.

The current source identifies these opportunities, not measured speedups:

- Tasks' Rust mutation helper takes an argument vector and extends a second
  vector with it. Build one final request vector at its known capacity,
  writing the receipt envelope and arguments directly into it. Preserve the
  existing Zig client's stack-built envelope where its lifetime permits.
- Rooms validates owning replies on receipt, then parses them again for each
  view. Evaluate immutable, validated accessors that retain checked scalars or
  positions in the owned reply. Avoid another full validation on every view,
  a second payload copy, unsafe self-references, or a cache larger than the
  parsing it replaces. Keep repeated parsing if measurements favor it.
- Rooms already retains complete mutation and issuance arguments for exact
  replay. Preserve that ownership when moving it into the library. A retry
  reuses the request envelope and identity, without rebuilding policy vectors
  or obtaining a new sequence. Transport encoding still runs as required.
- Keep returned references and reply storage under their existing owners.
  Borrow fields for synchronous consumption and copy only what escapes that
  lifetime. Typed wrapping must not clone a payload or retain the same
  capability again solely to attach its interface type.

Do not duplicate server admission in the client or cache an authorization
decision. Scope, status, revision, and ancestor changes remain checked at use.
Only immutable interface metadata may be prepared at registration. Count the
registration memory and generated code size as well as steady call costs.

For each migrated workload, require no increase in network or storage effects,
allocation count, copied bytes, or peak retained bytes. Attribute CPU changes
with the existing phase profiler and compare repeated ReleaseFast latency and
throughput runs. Establish run-to-run variation before judging timing. Resolve
a reproducible regression rather than hiding it in an aggregate average.

Use the existing Loam profile for the shared Zig path. Add focused client
phase coverage for request building and reply access in Rust, which that
profile does not execute. Measure the complete application call as well as
the isolated phase before claiming an improvement.

Allocation and effect assertions join the owning tests, with negative probes
that demonstrate they catch an added copy or call. Timing results record the
baseline and candidate revisions, commands, workload, and variability. Planning
runs no benchmarks. Capture and compare measurements only after the benchmark
pause is lifted, and leave performance acceptance open until then.

## Steps

Each numbered step is one commit with its own passing evidence. If a step
cannot remain reviewable as one commit, split it here before implementing it.
Delete completed steps in their landing commits. Gates below run through the
project's development environment front.

### 1. Record the interface and ownership contract

Write an ADR for the decisions above. Specify the public namespaces, retained
reference ownership, interface descriptor, reserved methods, error mapping,
retry identity, and cancellation behavior. Distinguish persisted names from
held capabilities and content-page graphs from resource trees.

Keep the existing fixed-resource lifecycle working. New foreign operations
extend its existing attachment and work ownership rather than add an
alternative store type. Record any required ABI layout changes and require
regeneration in the commit that changes them.

Acceptance: the ADR accounts for each contract above and amends the relevant
accepted decisions. Run `zig build source-check`. This step changes no runtime
behavior and does not claim that the interface exists.

### 2. Add the bounded Zig typed client

Add interface descriptors, typed resource and control owners, and application
call encoding and reply decoding. Separate capability ownership from borrowed
reply data. Keep registration and client descriptors checked by the same Zig
validation. Add registration rejection for reserved method collisions. Record
the Tasks baseline before replacing its client helpers, and test the final
request envelope's allocation and copy bounds.

Acceptance: Tasks' board, list, and task declarations call each interface over
an existing Host, replacing the Zig client's generic reply helpers. Wrong
local call types fail compilation. Wrong remote replies, policy
identities, versions, oversize values, and closed or foreign-Host references
fail at runtime without an application callback or retained-reference leak.
Compile-failure fixtures must be registered in a check that actually runs.
Run `zig build test` and `zig build check`.

### 3. Complete typed sharing and management

Project existing sharing, inspection, policy edits, pause, resume, revoke,
control attenuation, scoped inventory, observation, and durable-name methods.
Reuse their request decoders and receipt machinery. Return typed use and
control values separately. Retained cursors and replies own their storage.

Acceptance: Tasks shares a listed task, narrows its
policy, pauses and resumes it, then revokes it. Every copy and descendant
refuses after revocation while an independent grant remains usable. Cover
initially paused issuance, ceiling and depth refusal, stale revisions,
identical retry, changed-input retry, and malformed management replies.
Observation and inventory expose no siblings outside held scope. Run
`zig build test` and `zig build check`.

### 4. Project bounded resource-tree calls through C

Expose child declarations, loaded participants, participant content edits,
and structural effects through the existing foreign registration and call
handles. Zig resolves the participants, admits every required grant, and
commits all effects once. Preserve the existing bounds on participants,
creation, and same-owner changes. A callback receives checked borrowed views,
not raw storage internals or caller-selected trusted identities.

Acceptance: C callbacks create a child, then a separate call moves an existing
child between two parents in one acknowledged operation. An out-of-scope or foreign-owner participant refuses
before invocation. A refused move changes no content, tree, revision, or
receipt. Replaying a successful move returns its original result. Run
`zig build loam-abi-test`, the generated Loam header and layout checks, and
`zig build check`.

### 5. Project the owner lifecycle through C

Expose staged creation, completion, committed metadata, restoration, and
registration of a multi-kind owner through existing Store and Work handles.
Keep bootstrap privileged and local. The public network interface never
accepts an owner key in place of a capability. Restore with no eager load of
the resource tree. Use the existing nonblocking storage execution path where
startup can wait for storage. Project bounded owner cleanup and retirement
through the existing trusted administration path, preserving resumable
progress and terminal endpoint behavior.

Acceptance: create an owner, publish its root, create descendants, close,
reopen, and fetch one descendant cold. Inject an aborted and an unknown
creation write. Neither publishes premature authority, and recovery resolves
the original operation before another creation can proceed. Duplicate
completion and early release refuse without losing the live work. Run
cleanup with a small work budget until retirement completes, then prove old
publications cannot restore working endpoints. Run `zig build loam-abi-test`,
the generated checks, and `zig build check`.

### 6. Add Rust typed references and tree registration

Expose typed resources and controls in a dedicated access namespace, leaving
existing persisted resource metadata distinct. Implement application traits,
checked conversions, share and control futures, and bounded tree callbacks
through the C projection. Reuse the existing Host, reference, attachment,
worker, panic, and shutdown owners.

Capture the Rooms baseline before moving its clients. Apply the performance
contract to request construction, repeated reply access, and replay. Reuse
the binding's existing exact-capacity policy encoders.

Move the reusable Rooms control, owning reply, prepared mutation, issuance,
and observation behavior into this interface. Update its callers and remove
the superseded implementation, retaining only Rooms-specific adapters. Move
Tasks' Rust board, list, and task calls onto the typed interface and delete
their repeated mutation and reply-shape helpers. Existing application method
names and meanings remain unchanged.

Acceptance: run Tasks' lifecycle over loopback, including child
creation, sharing, movement, conflict, and restart. Compile-failure tests
reject a mismatched request and control operation on a use reference. Runtime
tests reject malformed replies. Dropping futures during queued and submitted
work, callback panic, detach, and Host close retain or retire every owner
correctly. Existing Rooms prepared-control and browser request tests pass
through the shared implementation. Run `zig build loam-rust-test demo-tasks
rooms-rust-test` and `zig build runtime-check`.

### 7. Prove recovery, portability, and performance

Extend the existing managed crash and browser proofs to the new operations.
Run Tasks' create, share, move, revoke, and restore trace through SQLite and
LMDB, and the foreign
projection through the browser's existing storage executor. Cover a crash
before commitment and after commitment before reply, followed by an exact
retry from a fresh Host. Keep content and access changes all-or-nothing.

Acceptance: a revoked durable child stays revoked after cold restoration.
Owner reopen loads no whole tree. Capacity exhaustion refuses before effects.
Allocation accounting includes client request and reply storage, retained
references, and callback state. Loaded admission adds no allocator calls, and
wrapper bounds do not grow with total stored resources. Update the allocation
ledger for changed wire-path costs.

Performance acceptance: compare every migrated workload with its recorded
baseline under the performance contract. Add a refusal or malformed-reply
case, a cold restore, and repeated replies and retries to catch work moved
out of the usual success path. Require no reproducible latency or throughput
regression. Record improvements only where the matched measurements show
them. Include retained ownership through cancellation and teardown.

Run `zig build
loam-lmdb-test loam-sqlite-test loam-managed-crash-test loam-browser-test
loam-core-wasm-check` and the
project's `check`, `runtime-check`, and `check-external` gates. Record platform
limits honestly. Regenerate only the affected performance reports after the
benchmark pause is lifted. Pending measurements leave this step incomplete.

### 8. Replace examples with the supported interface

Use Tasks' migrated Zig and Rust clients as the complete examples. Document
how to create, share, inspect, edit, revoke, reopen, and
handle a conflict. Update the Loam guides, binding scope, shipped inventory,
and known limitations from the behavior proved above. Do not claim general
foreign tree support before its proofs pass.

Acceptance: the Tasks clients build and exercise the documented lifecycle
using the public interface. Run `zig build tasks-app-test demo-tasks examples
source-check` and the Rust consumer proof. Remove this plan and the roadmap
item in the same final commit.

## Parallel work

Use one implementation lane through steps 1–5. The client contract, C call
representation, generated files, and owner lifetime depend on each other.
Splitting these before their interfaces settle would create overlapping work.
After step 5 lands in `dev`, two lanes may proceed:

- The Rust lane owns step 6, the Rust binding and consumer fixtures, Tasks'
  Rust client, and the Rooms control client and its callers.
- The proof lane prepares step 7's Zig crash and capacity cases. Browser
  integration waits for step 6 and then belongs to the Rust lane.

The integration owner owns this plan, the roadmap, living docs, build-step
registration, C manifests, and all generated files. A lane needing a shared
file hands its change to that owner. Synchronize before regeneration. Step 8
starts only after both lanes' evidence passes. This describes implementation
ownership and does not start agents during planning.

## Questions for you

None beyond reviewing this scope before implementation. This plan deliberately
keeps the existing runtime, receipt model, storage formats unless extension is
required, and fixed-resource consumers. It does not wait on publication,
hosted CI, or Rooms product decisions. Required platform runs remain explicit
verification work rather than a reason to claim completion early.

## Where the code is

Existing implementation and evidence:

| Concern | Owner |
| --- | --- |
| Access exports and policy | `src/loam/access/mod.zig`, `src/loam/access/core/policy.zig` |
| Owner creation and server registration | `src/loam/access/hosting/owner.zig`, `service.zig` in that directory |
| Trusted owner cleanup | `src/loam/access/hosting/maintenance.zig`, `src/loam/access/storage/maintenance.zig` |
| Shared management encoding | `src/loam/access/hosting/vocabulary.zig`, `request.zig`, `control_request.zig` |
| Child creation and participants | `src/loam/access/hosting/creation.zig`, `participants.zig`, `commit.zig` |
| Admission and durable operations | `src/loam/access/storage/capabilities.zig`, `capability_operation.zig` |
| Foreign call projection and exports | `src/c_abi/loam/callbacks.zig`, `creation.zig`, `types.zig`, `symbols.zig` |
| Generated header and layouts | `tools/gen/header/`, `bindings/c-abi-resolve.json`, `bindings/rust/src/sys/loam_gen.rs` |
| Rust owners and argument construction | `bindings/rust/src/loam/mod.rs`, `policy.rs`, `observation.rs` |
| Tasks' existing tree and clients | `apps/tasks/zig/board.zig`, `storage.zig`, `client.zig`, `apps/tasks/rust/board.rs` |
| Rooms' reusable held-control client | `apps/rooms/rust/glowcap/src/client/access.rs`, `apps/rooms/rust/glowcap/src/client/access/` |
| Rooms' browser control consumer | `apps/rooms/rust/browser/src/attached/managed/control.rs`, `observation.rs` in that directory |
| Rooms' generated method declarations | `tools/gen/rooms_protocol.zig` and `gen-rooms-protocol-check` |
| Existing request allocation discipline | `bindings/rust/src/loam/policy.rs` |
| Existing performance attribution | `bench/README.md`, `tools/build/bench.zig`, `tools/build/loam.zig` |
| Zig tree and recovery proofs | `test/loam/access/tree_hosted_test.zig`, `test/loam/engines/tree_crash_test.zig` |
| C and Rust lifecycle proofs | `test/c_abi/loam_test.zig`, `bindings/rust/src/loam/tests/` |
| Shared foreign management traces | `bindings/proofs/_support/loam_management.rs` |
| Gate registration | `tools/build/gates.zig`, `tools/build/` |

Proposed additions are `src/loam/access/client/mod.zig` and
`bindings/rust/src/loam/access/mod.rs`, exported as
`glowcap.loam.access.client` and `loam::access`. Register the portable Zig
client's module imports and tests in the build graph. Keep it free of I/O
imports. The ADR fixes the public declarations before implementation.
The generated checks are `gen-header-loam-check` and
`gen-binding-loam-layout-check`, plus companion checks if their layouts change.
