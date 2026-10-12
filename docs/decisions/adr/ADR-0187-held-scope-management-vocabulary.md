---
id: ADR-0187
status: accepted
date: 2026-10-03
tags: [loam, bindings, authority, hosting]
decision: "Management decoders receive loaded held-control powers. The fixed-resource foreign vocabulary projects policy edits, managed derivation and control attenuation through shared Zig admission."
supersedes: []
superseded_by: []
amends: [ADR-0185]
amended_by: [ADR-0207]
---

# ADR-0187 Held scope for management vocabulary

## Context

The fixed-resource C/Rust/browser profile has content registration and derived
use references. Rooms requires separately held child controls and mutable policy
before replacing its session ledger. Policy-edit terms include scope, but the
original application decoder receives only wire arguments. An embedding would
have to reconstruct scope from caller-supplied identities or retain a parallel
map. Scope must come from the loaded control, so authority stays held and
admission stays shared.

## Decision

`access.hosting.Service` supplies loaded control powers to policy-edit and
attenuation decoders during retained preparation. Decoded terms borrow that
operation's scope through settlement. The shared operation admits edits,
attenuation and lifecycle changes. Decoding does not decide availability.
Repeated terminal grant revocation retains the model's idempotent result.

`src/c_abi/loam/vocabulary.zig` supplies one fixed-resource vocabulary for C,
Rust and browser attachments. `set-policy` replaces policy within the held
management scope. `derive-managed` returns an ordinary use/control pair with
explicit child management powers. `attenuate-control` returns a dependent
control with narrowed powers. Policy identities, unsigned masks and ordered
bounds keep their existing derivation encoding. Requests carry no resource
identities. Shared Zig policy, ancestry, ceiling and depth rules remain the
authority. Rust constructs arguments for existing Ref and Session calls.

## Scope

This profile covers policy editing and independent pause/resume/revoke powers
for fixed resources. It does not implement application labels, control-owned
issuance, branch inventory, general graph edits, saved-reference authoring or
owner lifecycle. Rooms still uses its session-specific ledger. Child controls
are recovered by exact managed-derivation receipt replay through a held source.
They are not given independent durable publications by this change.

## Alternatives considered

- Caller-supplied resource keys require every embedding to recover and check
  the same authority correspondence and expose a misleading identity surface.
- Binding-owned management rules create another source of policy semantics.
- An availability guard before the decoder changes shared lifecycle admission,
  including harmless repeated terminal revocation.

## Evidence and gate

`test/loam/access/hosting_test.zig` edits within loaded control scope and repeats
terminal revocation after cache eviction. The shared Zig management, grant and
storage scenarios own the semantic claims. `test/c_abi/loam_vocabulary.zig` checks shape
refusal, held scope and full unsigned bounds without new call allocations.

`bindings/proofs/_support/loam_management.rs` drives one consumer trace under
both `zig build loam-rust-test` and `zig build loam-browser-test`. It covers
equal and narrower children, power/depth/ceiling refusals, configured versus
effective descendant policy, paused edits, independent control retirement,
restart receipt replay and retained descendant revocation. These establish
consumer projection on Linux and Chromium, not target OS acceptance or the
unimplemented Rooms integration.
