---
description: "Zig glowcap test taxonomy, vocabulary, and conformance discipline."
globs: test/**/*.zig, src/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, test/oracle/**, build.zig
---

# glowcap — Tests and Conformance

Every test answers three questions: which **layer** is under test, what
**authority** decides "correct," and what a **failure** tells you. This rule is
the glossary that keeps the words for those answers honest and the map from each
answer to a directory. A test you cannot place on this map, or name with this
vocabulary, is a test whose boundary is unclear, fix the test, not the map.

## Vocabulary

One meaning each. A word that drifts off these is a bug in the test surface, not
a synonym.

- **gate** — a build _verb_: a `zig build` step whose exit code must be green
  (the `check` aggregate and its members). Never a test _category_. The cli
  vocabulary owns it; see the [cli rule](cli.md).
- **unit** — a module-internal invariant test. Authority is an internal Zig
  invariant; a failure points at that one layer.
- **scenario** — a whole-conversation observable trace, driven through the
  engine and compared against the oracle; a failure points at session or engine
  behavior, not at a codec or transport.
- **oracle** — the reference of truth a result is compared against: the
  `src/oracle/` trace generator and the `test/oracle/` corpus and arm registry.
- **conformance** — _external_ authority: an expectation that would still hold
  if glowcap were rewritten from scratch — the OCapN spec, the live Goblins
  peer, the upstream suite. It lives in `conformance/` and nowhere else.
- **interop** — _cross-implementation_ protocol interop: glowcap↔Goblins,
  glowcap↔glowcap over iroh. It lives in `interop/`. The C-ABI boundary between
  Zig and its bindings is never called interop — its authority is the C ABI
  contract, exercised by `test/c_abi` and the binding dogfoods.

## Authority

What decides "correct" is what a red test means:

- **Internal Zig invariant** — `foundation`, `model`, `codec`, `session`,
  `engine`, `actors`, `persistent`, `net`, `driver`. A failure is a bug in that
  one layer.
- **C ABI contract** — `c_abi` (including `header_parity_test.zig`, which
  `@cImport`s the generated header). A failure is a break at the FFI boundary.
- **The oracle** — `oracle`: the Syrup byte corpus, the message-arm registry,
  and the scenario traces. A failure is protocol drift. The corpus is
  glowcap-authored but Syrup-serialized by the upstream encoder, so the
  _strongest_ external authority is the sibling live steps (`goblins-interop`,
  `ocapn-conformance`), not the in-tree bytes — see
  [`test/oracle/README.md`](../../test/oracle/README.md).
- **Exported namespace** — `api_surface_test.zig`.

Benchmarks keep performance budgets visible; they do not prove correctness, and
a benchmark is never an authority for behavior.

Every deterministic test or proof process emitted by the build has an
owner-calibrated process-group deadline of at most 30 seconds. Zig bounds each
runner-launched subprocess, not its aggregate suite; local protocol deadlines
remain diagnostic. A proof that drives a real browser names the bounded
`browser_proof` posture instead: its wrapper is the scenario's own deadline
plus headroom, never a shorter number the scenario contradicts. Benchmark,
search, real-internet, service, and build work name their posture explicitly —
none is a silent exemption.

## Protocol Claims Need Scenarios

Any claim about codec-neutral behavior, session state, engine behavior, C ABI
frame ownership, or cross-codec semantics needs a test or oracle trace.

Do not use another implementation as the semantic authority in prose. If a
consumer-dogfood comparison matters, name the checked boundary and the remaining
gap explicitly.

## A New Property Test Is Validated Against Defects

A property or fuzz target that passes on a healthy tree has shown nothing: the
tree was already healthy. Before landing one, break the code it targets — one
injection per defect class the target claims to cover — and confirm the search
finds each. An escape is a finding about the harness, not the code. Record in
the target's header which defects it was validated against, and which states it
measured itself as *not* reaching; a green run means only what those two lists
say it means. `test/net/fuzz_test.zig` carries a worked example of
both, including the escapes that shaped it.

## Placement

- `test/foundation`: byte ownership and ID invariants.
- `test/model`: codec-neutral model types and structural equality.
- `test/codec`: encode/decode fixtures, borrowed-view behavior, and per-arm
  cross-codec equivalence (Syrup and Cap'n Proto decode to the same model).
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
- `test/cli`: hermetic CapTP CLI goldens (registry, fronts, exit codes, CapTP
  deadline hang-proof, in-process listen/call adapter), run by
  `zig build cli-test` (also part of `check`); not wired through `all_test`
  because the product binary lives outside `src/`. CapTP dials in this tree
  name a finite handshake budget; `.unbounded` is a hang, not a slow test —
  see the [cli rule](cli.md). Product-adapter proofs use
  `cli/test_api.zig` in-process; ad-hoc live CapTP in an agent session is the
  product binary via the [glowcap-cli skill](../skills/glowcap-cli/SKILL.md).
  Do not invent a parallel Zig dialer outside `cli/` / `test/cli/`. A shell
  echo is not Goblins/suite wire evidence
  ([community-review](../../docs/community-review.md)).
- `test/c_abi`: C ABI layout and ownership vocabulary.
- `test/oracle`: the protocol oracle, message-arm manifests, the checked-in
  Syrup byte corpus under `test/oracle/corpus/` with its generators, fixture
  loaders, and whole-conversation scenario traces compared against the oracle.
- `test/codec/fuzz_regressions`: inputs the fuzzer found, replayed by the
  ordinary suite so a crash it caught cannot return quietly. `zig build fuzz`
  writes them; `source-check` refuses one that is not wired into the replay.
- `test/support`: shared test helpers, including the copy utilities production
  modules must not carry.
- `test/api_surface_test.zig`: recursively references every exported `glowcap`
  declaration, so an unreferenced public API cannot rot unanalyzed.
- `bindings/rust`: Rust C ABI consumer smoke tests, run by
  `zig build rust-dogfood`.
- `bindings/proofs`: hermetic per-binding proof families — one scenario per
  family, run once per binding, every peer glowcap. Authority is the C ABI
  contract, never interop; the Rust client of each family lives in
  `bindings/rust/examples/` because Cargo compiles examples there.

External conformance lives outside `test/`: the arbiters in
[`conformance/`](../../conformance/README.md) and the cross-implementation
drivers in [`interop/`](../../interop/README.md), each exercised by the runner
or sibling build step its README names, every `interop/` driver has a `zig
build` step; a `conformance/` arbiter may instead carry its own `run.sh`. Gates
and focused build steps live in the [cli rule](cli.md).
