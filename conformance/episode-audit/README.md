# reference/tests/episode-audit/

> **Runtime.** Devcontainer-only. Shares
> [`tools/non-pixi-lazy-install/`](../../../tools/non-pixi-lazy-install/)'s
> cache with `accountability-on-goblins/`; libsodium from conda-forge.

End-to-end test scenario: print and verify the signed-Episode trace
produced by [`reference/implementations/accountability-on-goblins/`](../../implementations/accountability-on-goblins/).

This is a **scenario**, not an implementation. The audit logic lives
in accountability-on-goblins's `racket/audit.rkt` (which depends on its
`identity.rkt` + `episode.rkt`). This wrapper just runs that file
natively from inside the sibling's `racket/` tree with
`GOBLINS_DATA_DIR` pinned at the sibling's `.data/`.

## Layout

```
episode-audit/
├── README.md                  ← this file
├── pixi.toml                  ← pixi project manifest declaring the audit task
└── run.sh                     ← thin wrapper for `pixi run <task>`
```

No `racket/` tree of our own — `audit.rkt` lives with the sibling
(`accountability-on-goblins/racket/audit.rkt`), and pixi just
invokes it with the right `cwd` + env. One less code path to keep
in sync on KERI primitive changes.

## What this checks

For each Episode in `accountability-on-goblins/.data/episodes.jsonld`, the
audit:

- Loads the per-AID KEL referenced by `kel_anchor.aid` /
  `kel_anchor.seq`.
- Verifies the Episode's ephemeral key is signed by the AID at that
  sequence.
- Verifies the Episode payload is signed by the ephemeral key.
- Prints a one-line summary: actor, invoked-affordance, valid-time,
  authority-grant, signature-chain status.

A green run is the claim that accountability-on-goblins's "every invocation
produces a verifiable Episode" invariant is honest, not asserted.

## Running

```bash
# 1. Produce Episodes (run any accountability-on-goblins demo).
bash reference/implementations/accountability-on-goblins/stack/run.sh kernel

# 2. Audit them.
bash reference/tests/episode-audit/run.sh audit
```

## Posture

- **Reads only.** The audit opens the sibling's `.data/` for read.
- **Coupled to accountability-on-goblins.** Verifies its outputs specifically.
- **Sibling to [`../keri-conformance/`](../keri-conformance/)** —
  same target (accountability-on-goblins's `.data/`), different verifier
  (Racket-side semantic audit here vs Python-side keripy spec
  conformance there).
- **Not in pancake's link gate** — see [`reference/README.md`](../../README.md).
- **Forward-looking.** Pancake's protocol core (per
  [`docs/planning/staging.md`](../../../docs/planning/staging.md)) is
  codec-neutral CapTP with no Episode emission or signed
  authority trace today. The integration model on the pancake side is
  wrapping: a consumer wraps
  [`pancake_runtime::Peer`](../../../crates/runtime/pancake-runtime/src/peer.rs)
  and intercepts at its own send/recv calls, the same shape this
  scaffold uses on the Goblins side. The identity-injection half is
  tracked design work for a future stage. Nothing here gates pancake's
  protocol-core acceptance.

## Links

- [`../../implementations/accountability-on-goblins/racket/audit.rkt`](../../implementations/accountability-on-goblins/racket/audit.rkt) — the audit logic
- [`../keri-conformance/`](../keri-conformance/) — sibling scenario: Python-side KERI conformance via keripy
