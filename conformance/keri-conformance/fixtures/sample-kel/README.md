# sample-kel: frozen `.data/` fixture for `keri-conformance`

A minimal KEL and Episode set for one AID
(`EGwvjOKrp-CMFkuIh2Gov2dQ4T3MvRArxB-SNEoGWPFO`), captured from an
`accountability-on-goblins` kernel run on 2026-04-30. It lets the Python KERI
verifier run without first invoking the Racket kernel.

## Contents

- `kel/<aid>.kel.jsonl`: two events: inception (`icp`, `s=0`) + rotation
  (`rot`, `s=1`). Pre-rotation discipline holds: the rotation's `k[*]`
  Blake3-256-hashes to the inception's `n[*]` digest.
- `episodes.jsonld`: one Episode anchored at `kel_anchor.seq=1` (the rotation
  key), `crypto_suite=ed25519-blake3-cesr-v1`.

It is one slice of the four-AID `.data/` that the kernel writes under
`conformance/accountability-on-goblins/.data/`.

## What is left out

- **Private keys** (`.sk` files in the source `.data/keys/`). The verifier
  checks signatures against the public verkeys embedded in each KEL event and
  never reads `.sk`.
- **Transparency log** (`transparency.log`, `transparency.root`). The verifier
  does not consume them. The separate `episode-audit` scenario does.
- **Other AIDs.** The source `.data/` holds three more. They pass the same
  verifier and add no regression coverage.

## How to refresh

When the kernel's KERI primitives change shape:

1. In the devcontainer, run
   `( cd conformance/accountability-on-goblins && racket racket/kernel.rkt )`
   to regenerate the source `.data/`.
2. Pick one AID's KEL and its matching Episode (the Episode's `kel_anchor.aid`
   must match a committed KEL filename). Copy both files here, overwriting the
   old ones.
3. Run `bash conformance/keri-conformance/run.sh --fixture sample-kel` and
   confirm it passes.
4. Commit the refreshed fixture in the same change as the kernel's KERI
   primitives.

`run.sh --fixture <name>` exports `GOBLINS_DATA_DIR` as
`keri-conformance/fixtures/<name>`, and `oracle/verify.py` reads that variable
to find its data.
