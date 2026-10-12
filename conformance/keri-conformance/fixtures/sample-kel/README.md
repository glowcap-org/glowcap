# sample-kel: frozen `.data/` fixture for `keri-conformance`

Captured from a real `accountability-on-goblins kernel` run on 2026-04-30.

## What this is

A minimum reproducible KEL + Episode set covering one AID
(`EGwvjOKrp-CMFkuIh2Gov2dQ4T3MvRArxB-SNEoGWPFO`):

- `kel/<aid>.kel.jsonl`: two events: inception (`icp`, `s=0`) + rotation
  (`rot`, `s=1`). Pre-rotation discipline holds: the rotation's `k[*]`
  Blake3-256-hashes to the inception's `n[*]` digest.
- `episodes.jsonld`: one Episode anchored at `kel_anchor.seq=1` (the rotation
  key), `crypto_suite=ed25519-blake3-cesr-v1`.

The source four-AID `.data/` lives under
[`../../../accountability-on-goblins/.data/`](../../../accountability-on-goblins/.data/).
This fixture is one coherent slice of it, so the Python KERI verifier can run
without first invoking the Racket kernel.

## What is NOT in this fixture

- **Private keys** (`.sk` files in the source `.data/keys/`). The oracle
  verifies signatures using the public verkey hashes embedded in each KEL event.
  It never reads `.sk`.
- **Transparency log** (`transparency.log`, `transparency.root`). The oracle
  does not consume them. The Episode-audit Racket scenario does (and runs
  separately).
- **Other AIDs.** Three more AIDs exist in the source `.data/`. They pass
  the same verifier but add no coverage to the regression check.

## How to refresh

When the kernel's KERI primitives change shape:

1. Run `( cd conformance/accountability-on-goblins && racket racket/kernel.rkt )`
   in a devcontainer to regenerate the source `.data/`.
2. Pick one AID's KEL + matching Episode (the Episode's `kel_anchor.aid` must
   match a committed KEL filename) and copy the two files into this fixture,
   overwriting the old contents.
3. Re-run `bash conformance/keri-conformance/run.sh --fixture sample-kel` to
   confirm the fixture still passes the oracle.
4. Commit the refreshed fixture in the same PR that changes the kernel's KERI
   primitives.

`run.sh --fixture <name>` exports `GOBLINS_DATA_DIR` pointing at this directory
(`keri-conformance/fixtures/<name>`) so the oracle's
`Path(os.environ.get("GOBLINS_DATA_DIR"))` reads it with no other change.
