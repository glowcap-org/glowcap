---
description: "Zig pancake test and conformance discipline."
globs: test/**/*.zig, src/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, test/oracles/**, build.zig
---

# pancake — Tests and Conformance

## Test Roles

- Unit tests prove local invariants.
- Oracle traces prove scenario behavior.
- Protocol manifests and Goblins fixtures pin external conformance pressure.
- Rust C ABI dogfood proves the pancake archives and their headers are
  consumable from a non-Zig caller.
- Benchmarks keep performance budgets visible; they do not prove correctness.

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
- `test/actors`: `Vat` turn loop, actor wire hosting over the engine, and local
  time-travel (snapshot/restore, copy-on-write, functional `become`).
- `test/persistent`: the persistent immutable map — structural sharing across
  versions, refcount correctness, and leak-freedom.
- `test/net`: stream framing, connection pump, TCP, and completion loop.
- `test/driver`: driver loopback — the owning `connect` / `listen` halves and
  the buffer-explicit `connectTcp` / `acceptTcp` halves, plus the application
  verbs over a real socket.
- `test/c_abi`: C ABI layout and ownership vocabulary.
- `test/conformance`: scenario trace comparisons.
- `test/oracle`: protocol message-arm manifests and fixture loaders.
- `test/oracles`: checked-in fixture corpora consumed by Zig tests.
- `test/support`: shared test helpers, including the copy utilities production
  modules must not carry.
- `test/api_surface_test.zig`: recursively references every exported `pancake`
  declaration, so an unreferenced public API cannot rot unanalyzed.
- `bindings/rust`: Rust C ABI consumer smoke tests, run by
  `zig build rust-dogfood`.

Gates and focused build steps live in the [cli rule](cli.md).
