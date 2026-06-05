# Re-homing pancake's reference material into the Zig tree

Status: in flight. This doc is the plan of record for moving the load-bearing
reference content out of the Rust workbench (`reference/` in the Rust repo) and
into this repository, where the devcontainer already provides every runtime
(Zig, Racket + patched Goblins, Deno/Node, Rust, Python) natively.

## The line

- **Infra dependencies (NOT brought):** the language toolchains/runtimes and
  their regenerable caches (`.pixi/`, pixi env state). The devcontainer
  provides these natively, so they do not travel.
- **Load-bearing reference content (brought):** everything else — the OCapN
  conformance suite, the Goblins peer, the Goblins source/spec mirrors, the
  accountability application and its persisted corpus, the KERI/episode
  oracles, the Syrup byte fixtures, and the per-language FFI consumers.

"Our modified Goblins" is Goblins + the `crypto-lib` atomic-primitive patch,
installed via `raco`. That install path already lives here in
`.devcontainer/install-racket-goblins.sh`.

## Target layout

```
conformance/                 # external scenarios + their targets/oracles
├── ocapn-conformance/       # OCapN test suite (submodule) + invocation wrapper
├── goblins-peer/            # slim Goblins peer + seven-caps conformance target
├── accountability-on-goblins/  # KERI app on Goblins + .data/ corpus
├── keri-conformance/        # keripy oracle + fixtures
├── episode-audit/           # audit.rkt
├── spritely-goblins/        # Goblins source mirror (submodule) — wire-shape lookup
├── ocapn-spec/              # OCapN spec mirror (submodule) — citations
└── syrup/                   # Syrup spec mirror (submodule) — citations

bindings/                    # per-language consumers of the Zig libpancake
├── rust/                    # was rust-dogfood/
├── deno/                    # was reference/implementations/pancake-deno
├── python/                  # was reference/implementations/pancake-python
└── racket/                  # was reference/implementations/pancake-goblins

test/oracles/                # fixtures gated by `zig build oracle-check`
├── goblins/                 # pancake shapes via upstream Racket Syrup encoder (path name historical, not Goblins-emitted) + generator
└── syrup/                   # positive + negative Syrup corpus + generator
```

## Submodules (pinned to the Rust repo's current pins)

| Path | URL | Pin |
| --- | --- | --- |
| `conformance/ocapn-conformance/upstream` | github.com/ocapn/ocapn-test-suite.git | `74db78f` |
| `conformance/spritely-goblins/upstream` | codeberg.org/spritely/racket-goblins.git | `bb661a5` |
| `conformance/ocapn-spec/upstream` | github.com/ocapn/ocapn.git | `18400d8` |
| `conformance/syrup/upstream` | github.com/ocapn/syrup.git | `931fa52` |

`conformance/bootstrap-submodules.sh` initializes them idempotently.

## Bindings: repoint to the Zig C ABI

The Rust bindings targeted the Rust three-cdylib family (runtime + net-tcp +
net-iroh, a `last_error` seam, netlayer endpoints). This repo's `pancake.h`
exposes only the peer/frame surface (`pancake_peer_new` / `feed_borrowed` /
`feed_owned` / `step` / `take_outbound` / `poll_event` + frame/event release).

Each binding therefore lands a **Zig-ABI-backed smoke consumer** mirroring
`bindings/rust` (load `libpancake`, create a peer, feed `op:abort` and
`op:gc-answers` frames, assert the surfaced event kind), wired into a new
`zig build bindings` step folded into `zig build check`. The relocated
netlayer / handshake / full-CapTP scenario code is preserved alongside but
marked **pending** the C ABI's growth — not falsely wired, not deleted.

## Out of scope

- Touching the Rust `reference/` (copy, leave intact for now).
- Growing the Zig C ABI to cover netlayers/handshake (the follow-up that
  unblocks the full binding scenarios).

## Verification status

- `zig build` builds `libpancake.{a,so}`; the **deno** Zig-ABI smoke passes
  against it (verified). The python/racket smokes mirror the same verified
  ABI layout and run in this repo's devcontainer (python3/racket on PATH).
- `zig build check` is green: the full Zig unit-test suite, both examples, the
  Rust C ABI dogfood, the oracle checks, and the arch gate all pass. The dogfood
  feeds an `op:gc-answers` (`<13'op:gc-answers[11+13+]>`) releasing
  answer-positions a fresh peer never owned and asserts the fail-loud contract:
  the frame decodes cleanly, so the borrowed-view dispatch rejects it as a
  session state-machine refusal (`PANCAKE_ERR_SESSION`, per ADR-0008 wire-delta
  GC — an unknown answer-pos is a loud error, never a silent clamp) and projects
  a typed `op:abort` onto the outbound queue. The C ABI now distinguishes a
  session refusal (`SESSION`) from a malformed frame (`CODEC`). The per-language
  smokes exercise the `op:abort` path.

## Intentional differences from the Rust corpus

- **No `op:release`.** Per ADR-0008 (Goblins-canonical Syrup wire profile),
  there is no `op:release` arm at any layer — GC is split into `op:gc-exports`
  + `op:gc-answers` with wire-delta reference counting. The Rust corpus carried
  a stray `op_release.bin`; the generators copied from it
  (`test/oracles/generate.py`, `test/oracles/goblins/generate.rkt`) still
  emitted it, so they were corrected. The corpus, both generators, and the
  `@embedFile` manifest omit it. This is not a gap to fill — do not reintroduce
  it.

## Follow-ups

- The per-scenario READMEs copied from the Rust workbench still carry some
  Rust-relative links (`../../tools/...`, `../../tests/...`). The canonical
  navigation is `conformance/README.md` + `bindings/README.md`; a link sweep
  over the copied READMEs is a follow-up.
