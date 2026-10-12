# conformance/

External conformance checks for glowcap: the authorities for correct behavior
that would hold even if glowcap were rewritten from scratch. This directory holds the
upstream OCapN test suite, the Spritely Goblins peer that glowcap dials, the
spec submodules kept for citation, the Goblins reference implementation of the
accountability application, and the KERI and episode reference verifiers that check it.
The worked accountability application *on glowcap* is not an authority. It lives
beside the other worked applications under
[`../apps/`](../apps/accountability-on-glowcap/). The live
cross-implementation drivers (glowcap talking to Goblins or to another glowcap
over iroh) are not external authority either. They live in
[`../interop/`](../interop/README.md).
The toolchains these need are Racket with Goblins and Python, which
[`../.devcontainer/`](../.devcontainer/) provides, so nothing here vendors its
own runtime.

## First-time setup

The `upstream/` directories are git submodules and are empty in a fresh clone.
The devcontainer fills them when it opens. From a checkout that has not been
through that hook (idempotent):

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

For a one-page map of what these build checks prove versus live Goblins interop, see
[`../docs/community-review.md`](../docs/community-review.md).

## Posture

- **Submodule `upstream/` trees are read-only.** Bump the pin, never edit in
  place.
- **Toolchains and their direct inputs are pinned.** Racket, Goblins, the
  direct Racket packages these checks add, and Python come from the
  devcontainer at committed versions. The crypto-lib atomic compatibility
  patch is committed and verified against both source and output hashes.
  Python wrappers use committed `uv` locks. The `run.sh` wrappers call
  `racket` / `uv run` directly. Racket's `--auto` dependencies resolve
  from its catalogs, so only the named direct package sources are pinned.
- **The canonical positive Syrup byte corpus lives at
  [`../test/oracle/corpus/`](../test/oracle/corpus/)** and is checked by
  `zig build oracle-check` (protocol reference fixtures). This directory holds
  the live, process-level checks that the in-tree reference corpus cannot
  capture.
