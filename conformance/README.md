# conformance/

External authorities for correct behavior, the checks that would still hold if
glowcap were rewritten from scratch. This directory holds the upstream OCapN
test suite, the Spritely Goblins peer that glowcap dials, the spec submodules
kept for citation, the Goblins reference implementation of the accountability
application, and the KERI and episode verifiers that check it.

Two neighbors are not authorities. The accountability application on glowcap
lives with the other worked applications in
[`../apps/`](../apps/accountability-on-glowcap/). The live drivers that connect
glowcap to Goblins, or to another glowcap over iroh, live in
[`../interop/`](../interop/README.md).

The toolchains are Racket with Goblins and Python. The
[devcontainer](../.devcontainer/) provides them, so nothing here vendors a
runtime.

## First-time setup

The `upstream/` directories are git submodules, empty in a fresh clone. The
devcontainer fills them when it opens. Elsewhere, run this (it is idempotent):

```sh
bash conformance/bootstrap-submodules.sh
```

## Layout

| Directory                                                  | What it is                                                                                                                    | Run                                                                 |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [`ocapn-conformance/`](ocapn-conformance/)                 | The upstream OCapN test suite (submodule) + a `uv` wrapper.                                                            | `bash conformance/ocapn-conformance/run.sh test '<ocapn-url>'`      |
| [`ocapn-findings/`](ocapn-findings/)                       | Neutral, reproducible discrepancy checks over the pinned OCapN spec, suite, and Goblins sources.                              | `zig build ocapn-findings-check`                                    |
| [`goblins-peer/`](goblins-peer/)                           | glowcap's slim Spritely Goblins OCapN peer: the seven-caps conformance target + TCP netlayer + demos.                        | `bash conformance/goblins-peer/run.sh seven-caps-peer`              |
| [`accountability-on-goblins/`](accountability-on-goblins/) | The Goblins reference implementation of the accountability application (KERI AIDs, signed Episodes, Merkle log). Its demos generate the `.data/` corpus the KERI and episode verifiers check. | (kernel/demos under `racket/`)                                      |
| [`keri-conformance/`](keri-conformance/)                   | Python reference verifier (keripy-checked primitives) that checks the KERI fixtures.                                                  | `bash conformance/keri-conformance/run.sh --fixture sample-kel`     |
| [`episode-audit/`](episode-audit/)                         | `audit.rkt` verifies each Episode's signature chain against the KEL.                                                        | `bash conformance/episode-audit/run.sh`                             |
| [`spritely-goblins/`](spritely-goblins/)                   | Goblins source (submodule), used for wire-shape lookup, not compiled here.                                                 | none                                                                |
| [`ocapn-spec/`](ocapn-spec/)                               | OCapN spec (submodule), kept for citations.                                                                                   | none                                                                |
| [`syrup/`](syrup/)                                         | Syrup spec (submodule), kept for citations.                                                                                   | none                                                                |

[`../docs/community-review.md`](../docs/community-review.md) maps what these
build checks prove against what live Goblins interop proves.

## Posture

- **Submodule `upstream/` trees are read-only.** Bump the pin, never edit in
  place.
- **Toolchains and their direct inputs are pinned.** The devcontainer fixes
  Racket, Goblins, the direct Racket packages these checks add, and Python at
  committed versions. The crypto-lib atomic compatibility patch is committed and
  verified against both source and output hashes. Python wrappers use committed
  `uv` locks. The `run.sh` wrappers call `racket` and `uv run` directly. Racket
  resolves `--auto` dependencies from its catalogs, so only the named direct
  package sources are pinned.
- **The positive Syrup byte corpus lives in
  [`../test/oracle/corpus/`](../test/oracle/corpus/)** and
  `zig build oracle-check` checks it. This directory holds the live,
  process-level checks that corpus cannot capture.
