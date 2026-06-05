# reference/tests/keri-conformance/

End-to-end test scenario: verify that the KERI primitives in
[`reference/implementations/accountability-on-goblins/`](../../implementations/accountability-on-goblins/)
(plain-Racket Ed25519 + Blake3 + CESR + KEL + pre-rotation) produce
spec-conformant KERI outputs, by re-deriving SAIDs and re-verifying
signatures with independent Python primitives ([`pynacl`][pynacl] for
Ed25519, [`blake3`][blake3-py] for SAID hashing) and falling back to
[keripy][keripy]'s `Diger` / `Verfer` primitives when those packages
aren't loadable. keripy is the reference KERI implementation pancake
treats as the spec-side oracle for these primitives; the harness here
does **not** ingest events through keripy's full `Serder` pipeline.

This is a **scenario**, not an implementation. The thing being checked
is accountability-on-goblins's `racket/identity.rkt` + `racket/episode.rkt` +
`racket/log.rkt` outputs. The harness is a Python image that walks the
produced `.data/` tree and runs the checks listed below.

[keripy]: https://github.com/WebOfTrust/keripy
[pynacl]: https://github.com/pyca/pynacl
[blake3-py]: https://github.com/oconnor663/blake3-py

## Layout

```
keri-conformance/
├── README.md                  ← this file
├── pixi.toml                  ← pixi project manifest (deps + tasks)
├── pixi.lock                  ← committed lockfile pinning the conda env
├── oracle/
│   └── verify.py              ← walks .data/{kel,episodes.jsonld,transparency.log}
└── run.sh                     ← thin wrapper for `pixi run <task>`
```

## What this checks

The verifier walks `accountability-on-goblins/.data/` and asserts:

- Every event in every per-AID KEL file (`kel/<aid>.kel.jsonl`) has a
  matching SAID; signature(s) verify against the appropriate keys
  (inception against the event's own `k[*]`; rotation against the
  PRIOR event's `k[*]` at the prior `kt`).
- Pre-rotation commitments line up positionally across consecutive
  events (Blake3-256 of each new key matches the prior event's `n[*]`).
- Each Episode in `episodes.jsonld` declares a known `crypto_suite`,
  its `ephemeral_pubkey` is signed by the AID at the claimed sequence,
  and the payload is signed by the ephemeral key.

A green run is the claim that accountability-on-goblins's
"we-did-KERI-in-Racket" is honest at the primitive level, not asserted.
Witness receipts, interaction / delegation / TEL events, full CESR
streaming, weighted-fractional thresholds, and non-Ed25519 / non-Blake3
suites are explicitly out of scope — see
[`oracle/verify.py`](oracle/verify.py)'s module docstring for the full
in-scope / out-of-scope list.

## Running

```bash
# 1. Produce KERI outputs (run any accountability-on-goblins demo).
bash reference/implementations/accountability-on-goblins/stack/run.sh kernel

# 2. Verify them.
bash reference/tests/keri-conformance/run.sh verify
```

First invocation materializes the conda env into `./.pixi/`
(gitignored) — pinned Python 3.12, `pynacl`, `blake3`, plus
`keri==1.2.6` from PyPI on top, lockfile-tracked at `pixi.lock`.
Install pixi with `brew install pixi` or
`curl -fsSL https://pixi.sh/install.sh | bash`. Subsequent runs reuse
the cached env.

## Posture

- **Test-only.** The pixi env is never on pancake's runtime path;
  pancake takes no keripy dependency.
- **Reads only.** The data dir is treated as read-only by `verify.py`.
- **Coupled to accountability-on-goblins.** Verifies its outputs specifically.
  If you change KERI primitives there, this is the gate that says
  whether the change is still spec-conformant.
- **Not in pancake's link gate** — see [`reference/README.md`](../../README.md).
- **Forward-looking.** Pancake's protocol core (per
  [`docs/planning/staging.md`](../../../docs/planning/staging.md)) is
  codec-neutral CapTP with no identity layer. The integration
  model on the pancake side is wrapping: a consumer wraps
  [`pancake_runtime::Peer`](../../../crates/runtime/pancake-runtime/src/peer.rs)
  and intercepts at its own send/recv calls, the same shape this
  scaffold uses on the Goblins side. The identity-injection half is
  tracked design work for a future stage. Nothing here gates pancake's
  protocol-core acceptance.

## Links

- [keripy upstream](https://github.com/WebOfTrust/keripy)
- [`oracle/verify.py`](oracle/verify.py) — what's actually checked
- [`../../implementations/accountability-on-goblins/`](../../implementations/accountability-on-goblins/) — the KERI implementation under test
- [`../episode-audit/`](../episode-audit/) — sibling scenario: Racket-side Episode audit
