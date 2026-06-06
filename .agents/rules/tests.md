---
description: "Zig pancake test and conformance discipline."
globs: test/**/*.zig, src/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, test/oracles/**, build.zig
---

# pancake — Tests and Conformance

## Test Roles

- Unit tests prove local invariants.
- Oracle traces prove scenario behavior.
- Protocol manifests and Goblins fixtures pin external conformance pressure.
- Rust C ABI dogfood proves `libpancake` and `pancake.h` are consumable from a
  non-Zig caller.
- Benchmarks keep performance budgets visible; they do not prove correctness.
- Test support helpers live under `test/support`, not production modules.

## Protocol Claims Need Scenarios

Any claim about codec-neutral behavior, session state, engine behavior, C ABI
frame ownership, or cross-codec semantics needs a test or oracle trace.

Do not use another implementation as the semantic authority in prose. If a
consumer-dogfood comparison matters, name the checked boundary and the remaining
gap explicitly.

## Placement

- `test/foundation`: byte ownership and ID invariants.
- `test/model`: codec-neutral model types and structural equality.
- `test/codec`: encode/decode fixtures and borrowed-view behavior.
- `test/session`: validation and state transitions.
- `test/engine`: `Peer` dispatch, ownership, events, outbound drain.
- `test/c_abi`: C ABI layout and ownership vocabulary.
- `test/conformance`: scenario trace comparisons.
- `test/oracle`: protocol message-arm manifests and fixture loaders.
- `test/oracles`: checked-in fixture corpora consumed by Zig tests.
- `rust-dogfood`: Rust C ABI consumer smoke tests.

Run `zig build check` before calling code work complete. Use focused steps such
as `zig build test`, `zig build meta-check`, `zig build oracle-check`,
`zig build rust-dogfood`, `zig build examples`, and `zig build bench-frame-view`
while iterating.
