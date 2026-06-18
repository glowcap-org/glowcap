# test/oracles/

Fixtures and generators the `zig build oracle-check` gate consumes.

These are **pancake-authored** Syrup byte vectors, not Goblins captures. Each
generator hand-builds the record structure that pancake's own codec produces for
a given `Message`, then serializes that record through the **upstream Syrup
encoder** (`ocapn/syrup`). Neither generator imports or runs Spritely Goblins.

- [`goblins/expected/`](goblins/expected/) — the canonical Syrup byte corpus.
  `@embedFile`d by
  [`../oracle/protocol_oracle.zig`](../oracle/protocol_oracle.zig) and asserted
  against the Zig encoder/decoder by
  [`../oracle/fixture_parity_test.zig`](../oracle/fixture_parity_test.zig). The
  `goblins/` path name is historical (the Racket/Goblins-ecosystem Syrup encoder
  produced this variant); the bytes encode pancake's chosen shapes, not Goblins
  output.
- [`goblins/generate.rkt`](goblins/generate.rkt) — pancake's record shapes
  serialized via the **upstream Racket Syrup encoder** (`syrup/syrup`). It runs
  under the devcontainer's Racket and does not require `goblins/...`.
  `zig build fixture-gen-check` reruns it and byte-compares the output against
  the committed corpus, so generator/corpus drift fails loud.
- [`generate.py`](generate.py) — the same pancake record shapes serialized via
  the **upstream Python Syrup encoder** (`syrup.py`), a by-hand cross-check (the
  devcontainer does not install `syrup.py`).

The two generators agreeing byte-for-byte proves only that the two upstream
Syrup _serializers_ agree on pancake's records — it does **not** establish that
Goblins independently emits these messages. Goblins-canonical authority comes
from a live Goblins peer captured on the wire (see
[`../../conformance/goblins-peer/`](../../conformance/goblins-peer/)) and the
OCapN conformance suite, not from these generators.

The Racket encoder is wired into `zig build fixture-gen-check`, which
regenerates the corpus and diffs it against the committed bytes on every gate.
The Python encoder rendered the same bytes in a one-time by-hand cross-check; it
is not gated (the devcontainer does not install `syrup.py`). The corpus lives
here once rather than in a separate directory per encoder.
