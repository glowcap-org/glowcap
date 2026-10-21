---
description: "Test taxonomy, vocabulary, and conformance discipline."
globs: test/**, interop/**, conformance/**/*.zig, bindings/proofs/**
paths:
  - "test/**"
  - "interop/**"
  - "conformance/**/*.zig"
  - "bindings/proofs/**"
---

# glowcap — Tests and Conformance

Every test names its layer, the authority that decides "correct," and what a
failure means. A test that fits nowhere on this map has an unclear boundary, so
fix the test.

## Vocabulary

- **gate:** a `zig build` step judged by exit code, never a test category.
- **unit:** a module-internal invariant. A failure points at that layer.
- **scenario:** a whole-conversation trace through the engine compared against
  the oracle. A failure points at session or engine behavior.
- **oracle:** `src/oracle/` traces plus the `test/oracle/` corpus and arm
  registry. The corpus is glowcap-authored, so the live steps
  (`goblins-interop`, `ocapn-conformance`) are the stronger authority.
- **conformance:** external authority (OCapN spec, live Goblins, upstream
  suite), only in `conformance/`.
- **interop:** cross-implementation runs, only in `interop/`. The Zig-to-binding
  C ABI boundary is never interop, and `test/c_abi` and the binding checks own it.

Benchmarks keep budgets visible and never decide behavior. A claim about
codec-neutral behavior, session state, engine behavior, frame ownership, or
cross-codec semantics needs a test or oracle trace. Never cite another
implementation as the authority in prose.

## Discipline

- A proof that reads rendered prose does so through the catalog or a marker
  the catalog owns. Rewording user-visible text means sweeping the test page
  helpers for the old wording in the same change, or the mismatch reads as a <!-- status-allow: workflow sequence -->
  flake.
- Every deterministic non-Zig test process has an owner-calibrated
  process-group deadline of at most 30 s, and Zig tests get `--test-timeout 30s`
  per test. Browser proofs use the `browser_proof` posture, a suite under
  valgrind uses `memcheck`, an orchestrator uses `child_bounded` only when
  every child wait is bounded, and benchmark, search, service, and build
  work name their posture explicitly.
- Bounded process checks stay quiet on success and replay output on failure.
- A new property or fuzz target is validated by injecting one defect per class
  it claims to cover and confirming the search finds each. Its header records
  what it caught and which states it does not reach
  (`test/net/fuzz_test.zig` is the worked example).
- An assertion whose expected value can be empty passes vacuously: a
  contains-check against an unset variable asserts nothing. Read expected
  values from a loader that is proven to have the data, and fail on an empty
  expectation instead of comparing with it.
- Tests that dial name a finite budget ([captp-waits](captp-waits.md)).
- Before deleting a test file with its subject, read every scenario in it and
  move each one that exercises a surviving surface: a file's name does not list
  everything it proves.

## Placement

- `test/foundation`: byte ownership and ID invariants.
- `test/model`: model types and structural equality.
- `test/codec`: fixtures, borrowed views, Syrup and Cap'n Proto equivalence.
- `test/session`: validation and state transitions.
- `test/engine`: `Peer` dispatch, ownership, events, drain.
- `test/actors`: the Vat turn loop, actor wire hosting, time travel.
- `test/loam`: storage, collections, access, and hosting contracts. LMDB uses
  its own module, and process-kill proofs belong to `runtime-check`.
- `test/net`: framing, pump, TCP, and the completion loop.
- `test/driver`: driver loopback and application verbs over real sockets.
- `test/cli`: hermetic CLI goldens via `zig build cli-test`, using
  `cli/test_api.zig` in-process, outside `all_test`.
- `test/c_abi`: C ABI layout and ownership vocabulary.
- `test/oracle`: the oracle, arm manifests, Syrup corpus, scenario traces.
- Each layer's `fuzz_regressions/`: fuzzer finds the ordinary suite replays.
  Wire each into its layer's `fuzz_test.zig` replay.
- `test/support`: shared helpers, including copy utilities.
- `test/api_surface_test.zig`: references every exported declaration.
- `bindings/rust`: Rust consumer smoke tests via `zig build rust-dogfood`.
- `bindings/proofs`: per-binding proof families, every peer glowcap.

External arbiters live in [`conformance/`](../../conformance/README.md) and
cross-implementation drivers in [`interop/`](../../interop/README.md). Each
names its runner or build step.
