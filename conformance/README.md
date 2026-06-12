# conformance/

External conformance pressure for pancake. This directory holds the OCapN test
suite, the Spritely Goblins peer that pancake's interop dials, the worked
accountability application, and the KERI and episode oracles that arbitrate it.
The toolchains these need are Racket with Goblins and Python, and
[`../.devcontainer/`](../.devcontainer/) provides them natively, so nothing here
vendors its own runtime.

## First-time setup

The `upstream/` directories are git submodules and are empty in a fresh
clone. Initialize them in one shot (idempotent):

```sh
bash conformance/bootstrap-submodules.sh
```

## Layout

| Directory | What it is | Run |
| --- | --- | --- |
| [`ocapn-conformance/`](ocapn-conformance/) | The upstream OCapN test suite (submodule) + a native `uv` wrapper. | `bash conformance/ocapn-conformance/run.sh test '<ocapn-url>'` |
| [`goblins-peer/`](goblins-peer/) | pancake's slim Spritely Goblins OCapN peer — the seven-caps conformance target + TCP netlayer + demos. | `bash conformance/goblins-peer/run.sh seven-caps-peer` |
| [`accountability-on-pancake/`](accountability-on-pancake/) | Accountability-emitting application hosted by pancake itself, plus cross-language callers and a three-party attribution test. | `zig build accountability` / `zig build accountability-three-party` |
| [`goblins_interop/`](goblins_interop/) | Live OCapN conversation drivers against a real Goblins vat — both directions, plus the three-party handoff. | `zig build goblins-interop` / `zig build goblins-handoff` |
| [`accountability-on-goblins/`](accountability-on-goblins/) | Accountability-emitting application on Goblins (KERI AIDs, signed Episodes, Merkle log) + its persisted `.data/` corpus. | (kernel/demos under `racket/`) |
| [`keri-conformance/`](keri-conformance/) | Python oracle (keripy-checked primitives) that arbitrates the KERI fixtures. | `bash conformance/keri-conformance/run.sh --fixture sample-kel` |
| [`episode-audit/`](episode-audit/) | `audit.rkt` — verifies each Episode's signature chain against the KEL. | `bash conformance/episode-audit/run.sh` |
| [`spritely-goblins/`](spritely-goblins/) | Goblins source (submodule), used for wire-shape lookup and not compiled here. | — |
| [`ocapn-spec/`](ocapn-spec/) | OCapN spec (submodule), kept for citations. | — |
| [`syrup/`](syrup/) | Syrup spec (submodule), kept for citations. | — |

## Posture

- **Submodule `upstream/` trees are read-only.** Bump the pin, never edit
  in place.
- **Toolchains are native.** Racket + Goblins (with the crypto-lib atomic
  patch) and Python come from the devcontainer; the `run.sh` wrappers call
  `racket` / `uv run` directly.
- **The canonical positive Syrup byte corpus lives at
  [`../test/oracles/goblins/`](../test/oracles/goblins/)** and is gated by
  `zig build oracle-check`; this directory is the live, process-level
  conformance pressure that the in-tree oracle can't capture.
