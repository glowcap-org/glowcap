---
id: ADR-0207
status: accepted
date: 2026-10-06
tags: [loam, authority, storage, bindings]
decision: "Held controls independently inspect and issue within immutable ceilings; labels, revisions, child indexes and exact issuance receipts remain shared Loam state."
supersedes: []
superseded_by: []
amends: [ADR-0187]
amended_by: []
---

# ADR-0207 Independent managed issuance and indexed inventory

## Context

Rooms needs administration while use is narrowed, paused or unable to delegate.
Deriving through a use capability cannot supply that contract. Binding-owned
grant lists would also duplicate shared ancestry and lifecycle authority. The
Zig grant scenarios are the semantic authority; applications project them.

## Decision

`Control.Powers` has independent Inspect, Issue, Edit and DelegateControl powers
beside lifecycle powers. Issue and Edit each carry their own copied ceiling.
`GrantPlan.issue_control` checks immutable ancestor ceilings, depth and child
quotas without requiring use delegation or active use. Children retain ordinary
source ancestry, so pause, configured restrictions and revocation still govern
their effective use. Nonempty child management requires DelegateControl.

Grants own a validated label of at most 120 UTF-8 bytes and a committed revision.
Fresh edits and issuance compare the expected grant revision, including no-op
edits. Hosted replay first recovers the exact original receipt, then rechecks
held authority and result custody. Control-owned issuance uses the existing
derivation receipt window through `issue-access`; it is not a mutation that
creates another receipt family. Recovery can return paused use without granting
permission to invoke it. Revoked controls, revoked ancestry and out-of-scope
results refuse replay.

`GrantRecord.children` roots the existing sparse directory machinery. Issuance
and retirement update membership in their owning transaction. Inventory walks
only direct children of the held Inspect control, retains one child row, and
uses existing fixed grant-decoder scratch. Hosted pages contain at most 32 rows
and a conservative 64 KiB encoded allowance. Cursors bind the exact endpoint
identity, generation and Store revision; rows contain descriptive policy and
lifecycle data, with no publication secrets or returned authority.

The fixed-resource C/Rust/browser profile carries these operations as ordinary
Host calls. An administration binding associates a control with its canonical
content/resource without making that content callable through the control.

## Scope

This implements the shared management prerequisite. Rooms production startup,
its access editor and application-specific management metadata still use their
existing owners. General recursive resource editing is outside this profile.

## Alternatives considered

- A use-based issuance shim cannot issue while use is paused or terminal for
  delegation, and confuses separately held management with permission to use.
- A Rust grant mirror repeats authority and requires population-sized startup.
- A separate issuance receipt family duplicates the existing exact derivation
  intent, child/control custody and publication recovery window.

## Consequences

Grant, capability and endpoint prerelease record formats advance to version 2.
Old storage is rejected; no compatibility reader reconstructs authority.
Capability decoding reserves two complete scope selections in fixed operation
storage. Record, operation and page allowances remain independently bounded.

## Evidence and gate

`test/loam/access/grants_test.zig` proves issuance at delegation depth zero under
paused and narrowed source use. `management_inventory_cases.zig` checks
independent powers, labels, revisions and cold sparse pagination on both shared
storage and LMDB. `stored_capability_record_test.zig` exercises both maximum
ceiling selections. The common `bindings/proofs/_support/loam_inventory.rs`
journey projects issuance while paused, exact replay, cursor conflicts and cold
inventory through LMDB and IndexedDB. Owning gates are `test`, `loam-lmdb-test`,
`loam-abi-test`, `loam-rust-test` and `loam-browser-test`.
