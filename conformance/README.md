# conformance/

External conformance pressure for pancake: the arbiters of correct that would
hold even if pancake were rewritten from scratch. This directory holds the
upstream OCapN test suite, the Spritely Goblins peer that pancake dials, the
spec submodules kept for citation, the Goblins reference implementation of the
accountability application, and the KERI and episode oracles that arbitrate it.
The worked accountability application *on pancake* is not an arbiter — it lives
beside the other worked applications under
[`../examples/apps/`](../examples/apps/accountability-on-pancake/). The live
cross-implementation drivers — pancake talking to Goblins or to another pancake
over iroh — are **not** external authority either; they live in
[`../interop/`](../interop/README.md).
The toolchains these need are Racket with Goblins and Python, and
[`../.devcontainer/`](../.devcontainer/) provides them natively, so nothing here
vendors its own runtime.

## First-time setup

The `upstream/` directories are git submodules and are empty in a fresh clone.
Initialize them in one shot (idempotent):

```sh
bash conformance/bootstrap-submodules.sh
```

## Layout

| Directory                                                  | What it is                                                                                                                    | Run                                                                 |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [`ocapn-conformance/`](ocapn-conformance/)                 | The upstream OCapN test suite (submodule) + a native `uv` wrapper.                                                            | `bash conformance/ocapn-conformance/run.sh test '<ocapn-url>'`      |
| [`goblins-peer/`](goblins-peer/)                           | pancake's slim Spritely Goblins OCapN peer — the seven-caps conformance target + TCP netlayer + demos.                        | `bash conformance/goblins-peer/run.sh seven-caps-peer`              |
| [`accountability-on-goblins/`](accountability-on-goblins/) | The Goblins reference implementation of the accountability application (KERI AIDs, signed Episodes, Merkle log) + its persisted `.data/` corpus — the source the KERI and episode arbiters check. | (kernel/demos under `racket/`)                                      |
| [`keri-conformance/`](keri-conformance/)                   | Python oracle (keripy-checked primitives) that arbitrates the KERI fixtures.                                                  | `bash conformance/keri-conformance/run.sh --fixture sample-kel`     |
| [`episode-audit/`](episode-audit/)                         | `audit.rkt` — verifies each Episode's signature chain against the KEL.                                                        | `bash conformance/episode-audit/run.sh`                             |
| [`spritely-goblins/`](spritely-goblins/)                   | Goblins source (submodule), used for wire-shape lookup and not compiled here.                                                 | —                                                                   |
| [`ocapn-spec/`](ocapn-spec/)                               | OCapN spec (submodule), kept for citations.                                                                                   | —                                                                   |
| [`syrup/`](syrup/)                                         | Syrup spec (submodule), kept for citations.                                                                                   | —                                                                   |

## Posture

- **Submodule `upstream/` trees are read-only.** Bump the pin, never edit in
  place.
- **Toolchains are native.** Racket + Goblins (with the crypto-lib atomic patch)
  and Python come from the devcontainer; the `run.sh` wrappers call `racket` /
  `uv run` directly.
- **The canonical positive Syrup byte corpus lives at
  [`../test/oracle/corpus/`](../test/oracle/corpus/)** and is gated by
  `zig build oracle-check`; this directory is the live, process-level
  conformance pressure that the in-tree oracle can't capture.
