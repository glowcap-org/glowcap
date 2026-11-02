# test/oracle/

The protocol oracle: the reference of truth the Zig codec and the session
engine are checked against. The Syrup byte corpus and its generators live here
alongside the loaders and the scenario-trace tests that consume them.

The corpus is **glowcap-authored** Syrup byte vectors, not Goblins captures.
The generator hand-builds the record structure that glowcap's own codec
produces for a given `Message`, then serializes that record through the
**upstream Syrup encoder** (`ocapn/syrup`). It imports no Spritely Goblins.

- [`corpus/`](corpus/): the canonical Syrup byte corpus. `@embedFile`d by
  [`protocol_oracle.zig`](protocol_oracle.zig) and asserted against the Zig
  encoder/decoder by [`fixture_parity_test.zig`](fixture_parity_test.zig).
  `tools/check/source_check.zig` holds the corpus and the registry to each other in both
  directions, so a `.bin` with no registry row, or a registry row with no
  `.bin`, fails the gate.
- [`generate.rkt`](generate.rkt): glowcap's record shapes serialized via the
  **upstream Racket Syrup encoder** (`syrup/syrup`). It runs under the
  devcontainer's Racket. `zig build fixture-gen-check` reruns it and
  byte-compares the output against the committed corpus, so generator/corpus
  drift fails loud.
- [`scenarios/`](scenarios/): the drivers that run a `Peer` through one fixed
  protocol scenario each and return its wire bytes, which
  [`scenario_trace_test.zig`](scenario_trace_test.zig) and the fuzz and
  memcheck suites compare. The suites import them as the `scenarios` module.
- [`stage0_abort.trace`](stage0_abort.trace): the canonical observable trace
  that [`scenario_trace_test.zig`](scenario_trace_test.zig) asserts a driven
  Stage-0 abort produces.

The generator matching the committed bytes proves that glowcap's records
serialize the way the upstream Syrup encoder serializes them. It does **not**
establish that Goblins independently emits these messages. That external
authority comes from a Goblins peer exercised live over a socket
([`../../conformance/goblins-peer/`](../../conformance/goblins-peer/)) and the
upstream OCapN conformance suite.
