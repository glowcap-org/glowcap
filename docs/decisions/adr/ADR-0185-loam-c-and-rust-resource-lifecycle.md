---
id: ADR-0185
status: accepted
date: 2026-10-03
tags: [loam, bindings, ownership, storage]
decision: "Optional Loam C archives project fixed-resource hosting and LMDB effects into the existing Host. Zig owns policy, transactions and recovery."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0186, ADR-0187, ADR-0188, ADR-0233]
---

# ADR-0185 Loam C and Rust resource lifecycle

The browser transaction projection is specified by
[ADR-0186](ADR-0186-loam-browser-transaction-execution.md).
The managed-control vocabulary is specified by
[ADR-0187](ADR-0187-held-scope-management-vocabulary.md).
The scope below records the first LMDB profile.

## Context

The shared persistence and managed-access engines already implement durable
resources. A language consumer needs a complete resource lifecycle without
rebuilding graph admission, commit ordering or recovery. The boundary keeps the
sync no-I/O core and existing Host capability custody (ADR-0161).

## Decision

`src/c_abi/loam` projects bounded schema and policy descriptors, atomic fresh
resource staging, content registration, held endpoints and storage Work handles.
The optional `src/c_abi/loam_lmdb` companion opens exclusive LMDB custody and
executes submitted effects. It creates no actor runtime. Rust's `loam` feature
owns callback contexts and worker retirement while using ordinary Host, Ref and
Session owners. Rust's LMDB opening requires an explicit physical map budget,
separate from cache and staging limits. A proven-aborted startup commit returns
`UNCHANGED` with its storage cause retained in the diagnostic. Generic policy
and grant decisions remain in Zig.

An attachment borrows its Store and Host until successful detach. Copied method
tables survive registration. Foreign contexts survive all outstanding calls.
Rust callback registrations share the Host's existing Context for bounded panic
diagnostics. A caught panic refuses the call and records its local cause there.
An application refusal is returned without a duplicate journal entry. Work
occupies a fixed startup slot and retains submitted memory until the executor
physically retires, owner-thread completion consumes its result, and release
retires the slot. Completion reports consumption separately from its status, so
refusal inside a callback cannot lose ownership. Cancellation of a Rust observer
joins its worker or retains both handles for later completion. Queued
cancellation proves that no storage effect ran. An unknown write keeps the
core's barrier until the original worker retires and recovery proves commit or
absence.

Fresh creation returns names only after synchronous startup commitment. An
indeterminate creation retains its provisional result for recovery. Object keys
are privileged local metadata. Restoring them validates a committed rooted
endpoint before minting an ordinary held Host reference. Peers invoke held
capabilities or fetch authorized publications, never serialized object keys.

C implementation imports do not own symbol exports. Host and Loam archive roots
explicitly export their manifest. Importing implementation declarations into a
companion cannot emit another archive's family. ELF artifact inspection compares
each installed archive with its generated header.

## Scope

The first profile covers fixed-resource create/share/edit/restart/cold-reopen,
permission and ordered-bound descriptors, content replacement, mutation receipts
and the existing use/control wire methods. General graph transactions,
saved-reference authoring, application-specific derivation decoders and privileged
owner lifecycle are not projected. Browser storage is not implemented. This
consumer proof does not establish OS support or outside-peer conformance.

## Alternatives considered

- A separate binding policy or persistence runtime duplicates authority and
  creates divergent commit and shutdown owners.
- Per-effect C heap owners add allocation to every storage miss. Fixed slots
  reserve bounded custody at attachment startup.
- Treating a dropped future as worker cancellation can free memory while LMDB
  still reads it. Retirement is a physical boundary.
- Implicit export rooting allows implementation imports to leak symbols into
  companion archives and fail foreign links.

## Evidence and gate

`test/c_abi/loam_test.zig` exercises atomic creation/reopen, configuration refusal
before durable effects, Host/Store/Work release refusal, callback completion
refusal, duplicate completion and uncertain-write recovery. Zig's Loam storage
and managed-access suites remain semantic authority.

`bindings/rust/src/loam/tests.rs` exercises real TCP Sessions, derived sharing,
narrowed admission, edits, exact and conflicting receipt replay, ancestor
pause/resume and cold fetching the same publication after restart. Rust callback
panic containment and context-drop tests prove the projection boundary.
`work.rs` proves queued executor cancellation retires as unstarted. These are
consumer evidence, not another protocol oracle.

`loam-abi-test` belongs to `check`. `loam-rust-test` belongs to `runtime-check`
and includes Clippy and compilation with only the Loam feature. Generated
headers, layouts and callable mirrors are checked by `check`.
