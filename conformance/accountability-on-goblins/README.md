# reference/implementations/accountability-on-goblins/

> **Runtime.** Devcontainer-only. First task invocation lazy-installs
> Racket Minimal 8.16 + Spritely Goblins + `libblake3.so` via
> [`tools/non-pixi-lazy-install/`](../../../tools/non-pixi-lazy-install/);
> cached in the `pancake-non-pixi-lazy-install` named volume.
> libsodium comes from conda-forge.

A worked example of an **accountability-emitting application running on
Spritely Goblins** — KERI-anchored peer identity, bitemporal RDF-Star
Episodes per capability invocation, Sigstore-shaped local Merkle
transparency log over Episode hashes. Plain Racket on top of the Goblins
runtime; no Spritely-Goblins source modifications.

This is **not pancake**. It's a forward-looking artifact: a worked
example of the consumer side of the interfaces pancake will eventually
need to expose so the same accountability application can ride pancake
as its CapTP runtime instead of (or alongside) Goblins.

## Why this lives here

Per [`reference/README.md`](../../README.md), `implementations/` holds
artifacts that *implement something*. This directory implements an
*application* that exercises a CapTP runtime via two interfaces:

1. A **netlayer** the application can ride to host its capabilities on
   the network (here: a TCP netlayer in
   [`../goblins-peer/racket/tcp-netlayer.rkt`](../goblins-peer/racket/tcp-netlayer.rkt)).
2. An **identity hand-off** the application uses to bind capability
   invocations to a cryptographic principal (here: KERI AIDs anchored
   in per-AID Key Event Logs in [`racket/identity.rkt`](racket/identity.rkt)).
3. An **invocation observation point** so the application can emit a
   signed Episode for each capability call (here: a Goblins-internal
   Affordance pattern in [`racket/episode.rkt`](racket/episode.rkt) and
   [`racket/accountable-three-vat-demo.rkt`](racket/accountable-three-vat-demo.rkt)).

Goblins exposes (1) and (3) via its actor-spawn + bcom shape. Pancake
exposes (1) via its `Endpoint` trait (already in shape) and (3) via
the same wrapping pattern used here against Goblins: a consumer wraps
`pancake_runtime::Peer` and intercepts at its own send/recv calls.
Identity hand-off (2) is straightforward in both worlds since KERI
keys are Ed25519, which both runtimes already use for
`op:start-session`.

## How this informs pancake

pancake's `pancake-session` is the locus of authority decisions for
every `op:deliver` (Stage 0 work-in-progress per
[`docs/planning/staging.md`](../../../docs/planning/staging.md)). The
integration surface for an accountability adapter that wants to
replicate this directory's behavior — sign an Episode per inbound
deliver, attribute it to the actual remote caller identified by their
session keys — is pancake's `Peer::send` / `Peer::recv` API. The
adapter wraps
[`pancake_runtime::Peer`](../../../crates/runtime/pancake-runtime/src/peer.rs)
and intercepts at its own send/recv calls, the same shape this
Goblins-side reference uses against the Goblins runtime. The wrapping
layer names the timing of its interception (Attempt Episode durable
before delegating to `inner.send`, Outcome Episode appended after the
matching `Resolve` returns from `inner.recv`).

What pancake still owes the accountability story:

- An **identity injection** path so an adapter can hand the session
  the signing key for `op:start-session` (today the netlayer or runtime
  composes this; the design needs an explicit name). Tracked design
  work for a later stage, alongside real EdDSA crypto.

This directory is the existence proof that the application surface is
well-defined enough to design against; the wrapping integration story
is in pancake's tree (`Peer`'s send/recv API), the identity-injection
half is not yet.

## Files

### Entry points (driver scripts you run)

| File | Role |
| --- | --- |
| `racket/kernel.rkt` | The 8-step accountability loop (Invocation → Decision → Effect → Episode → Log) end-to-end against a single in-process Goblins `Vat` (Goblins's vocabulary; see [`docs/design/vocabulary.md`](../../../docs/design/vocabulary.md) — pancake doesn't lift the term). The `stack/pixi.toml` `kernel` task runs this. |
| `racket/accountable-three-vat-demo.rkt` | Three TCP peers + signed Episodes across an OCapN three-party introduction. Demonstrates that the accountability invariant ("every Invocation produces a verifiable Episode attributing the true caller") survives across Goblins-`Vat` boundaries reached via OCapN's three-party intro. Cross-tree require — see "[Cross-tree dependency on goblins-peer](#cross-tree-dependency-on-goblins-peer)" below. |
| `racket/audit.rkt` | Re-reads `.data/`, verifies signature chains, prints a human-readable trace. The driver wrapper is at [`../../tests/episode-audit/`](../../tests/episode-audit/). |
| `racket/probe-ffi.rkt` | KERI FFI smoke check (libsodium / libblake3 are loadable). |

### Libraries (Racket modules the entry points compose)

| File | Role |
| --- | --- |
| `racket/identity.rkt` | KERI in plain Racket: Ed25519 + Blake3 FFI, CESR encoding, SAID, pre-rotation, KEL persistence. Conformance verified externally by [`../../tests/keri-conformance/`](../../tests/keri-conformance/). |
| `racket/episode.rkt` | Episode emission — RDF-Star JSON-LD with bitemporal columns, ephemeral signing, transparency-log registration. |
| `racket/log.rkt` | Sigstore-shaped local Merkle transparency log over Episode hashes. |

### Internal tests (rackunit, not in `reference/tests/`)

| File | Role |
| --- | --- |
| `racket/tests/kernel-test.rkt` | End-to-end test of the 8-step kernel loop, run via `stack/run.sh test` (which invokes `raco test tests/kernel-test.rkt` inside the container via the `test` pixi task). Wipes `.data/` and re-runs `kernel.rkt` deterministically before asserting. |

### Schema + docs

| File | Role |
| --- | --- |
| `racket/shapes/episode.ttl` | SHACL shape declaration for `goblins:Episode` (validation runtime-deferred). |
| `racket/doc/KERNEL.md` | What the kernel demonstrates and what it deliberately does not. |

### Driver

| File | Role |
| --- | --- |
| `stack/run.sh` | Single-command launcher (no `cd` required); thin wrapper around `pixi run` against `stack/pixi.toml`. |
| `stack/pixi.toml` | pixi project manifest declaring the scenario's tasks (`kernel`, `test`, `run`, `shell`). Tasks invoke `racket` natively against `../racket/`; `_setup` precreates the writable `.data/` dirs. |

### Generated state (gitignored)

`racket/.data/` and `racket/tests/.data/` are written at runtime by
`kernel.rkt`, `accountable-three-vat-demo.rkt`, and `kernel-test.rkt`
(KEL files, signed Episode JSONL, transparency log + root). Both are
gitignored. The internal test wipes its `.data/` at the start of each
run for determinism; if you want to preserve a run's outputs for
inspection, copy them out before the next test invocation.

## Why demos live here, not in `reference/tests/`

The `reference/tests/` directory is for **external verifiers** —
Python keripy checking KERI conformance, the OCapN test suite
checking CapTP conformance — pointed at one of the implementations.
**Internal demos and rackunit tests live with the implementation they
exercise.** Same pattern as
[`goblins-peer/racket/`](../goblins-peer/racket/), which has
`tcp-demo.rkt`, `three-vat-demo.rkt`, and `seven-caps-peer.rkt`
alongside its libraries.

`accountable-three-vat-demo.rkt` is an internal demo that asserts
four invariants of the accountability impl (introduction worked,
Episode landed with correct actor, Episode verifies cryptographically,
introducer's log is silent). It reads as an executable demonstration
of "what this implementation does"; it isn't an *external* check on
something else's outputs.

If you find yourself wanting to run an external verifier against
`accountability-on-goblins`'s outputs, the right home is a new
[`reference/tests/<scenario>/`](../../tests/) directory.

## Cross-tree dependency on goblins-peer

[`racket/accountable-three-vat-demo.rkt`](racket/accountable-three-vat-demo.rkt)
requires [`../../goblins-peer/racket/tcp-netlayer.rkt`](../goblins-peer/racket/tcp-netlayer.rkt)
via relative path. The reason: the TCP netlayer is *transport
mechanism* (lives with the slim peer); KERI/Episode emission is
*application behavior* (lives here). The accountability impl conceptually
*sits above* the goblins-peer impl — it consumes the netlayer to
demonstrate that the accountability loop holds across cross-`Vat`
introduction (Goblins's vocabulary; pancake's own model uses
"peer" — see [`docs/design/vocabulary.md`](../../../docs/design/vocabulary.md)).

The `stack/pixi.toml` `kernel` / `test` / `run` tasks set
`cwd = "../racket"`, so the relative require resolves against the
checked-in tree directly — no bind-mount or container-side path
remapping. If `goblins-peer/` ever ships its TCP netlayer as a raco
package, this `require` becomes a normal package import and the
cross-tree dance goes away.

## Scope and limits

The vocabulary here (Affordance, Episode, Vat, KERI AID) belongs to
the accountability-application layer, not to pancake. pancake hosts
the codec-neutral CapTP boundary; these terms sit *above* it and
shouldn't be imported into pancake's surface.

The accountability loop is also not pancake-portable today. It's
wired through the Goblins runtime; porting it to ride pancake (the
accountability-on-pancake spike) is the motivation for the wrapping
integration pattern + the identity-injection design work.

Goblins itself lives in
[`../spritely-goblins/upstream/`](../spritely-goblins/upstream/),
pinned via submodule; this directory is not a Goblins implementation.
And this isn't the substrate's last word, either: the packaging
captures an earlier exploration of accountability-on-OCapN, while the
wider substrate work continues on its own outside this repo. Modify,
replace, or extend without ceremony.

## Running

```bash
# 8-step kernel demo (single-Actor accountability loop).
bash reference/implementations/accountability-on-goblins/stack/run.sh kernel

# Run kernel-test.rkt (8 tests).
bash reference/implementations/accountability-on-goblins/stack/run.sh test

# Three-party introduction + signed Episodes (~2-3s).
bash reference/implementations/accountability-on-goblins/stack/run.sh run accountable-three-vat-demo.rkt
```

Verifying outputs:

```bash
# Audit Episodes (verify signature chain, print trace).
bash reference/tests/episode-audit/run.sh audit

# Verify KERI conformance against keripy.
bash reference/tests/keri-conformance/run.sh verify
```

`.data/` behavior: see [Generated state](#generated-state-gitignored) above.

## Posture

- **Heavier dep surface than `goblins-peer/`.** Pulls in libsodium
  (conda-forge) and `libblake3.so` (built from source by
  [`tools/non-pixi-lazy-install/blake3.sh`](../../../tools/non-pixi-lazy-install/blake3.sh))
  for KERI primitives.
- **Editable.** Modify, replace, extend without ceremony. Generated
  `.data/` regenerates from source on the next run, so changing
  `identity.rkt` or `episode.rkt` doesn't cascade into stale signed
  artifacts.
- **Not in pancake's link gate** — see [`reference/README.md`](../../README.md).

## Links

- [`stack/pixi.toml`](stack/pixi.toml) — pixi tasks
- [`../goblins-peer/`](../goblins-peer/) — the slim Goblins peer this directory depends on
- [`../../tests/keri-conformance/`](../../tests/keri-conformance/) — KERI conformance against keripy
- [`../../tests/episode-audit/`](../../tests/episode-audit/) — Episode audit driver
- [Spritely Goblins](https://spritely.institute/goblins/)
