# tools/

These are maintainer tools, not product APIs. Checks, generators, and operator
scripts live here, and correctness scenarios live in top-level
[`test/`](../test/).

| Path | Owns |
|------|------|
| [`build/`](build/) | Step-registration modules the root `build.zig` composes: shared helpers, one module per extracted step family, and the content-stable library installer the install steps run |
| [`check/`](check/) | Build checks and hygiene (`arch_check`, `source_check`) |
| [`gen/`](gen/) | Header and binding generators, shared verify/emit harness |
| [`profile/`](profile/) | The callgrind part reader and report behind the `profile-*` steps: self cost per file and function for each phase a bench marks, and the callers of the leaf functions at the top |
| [`ab/`](ab/) | The runner behind `bench-ab`: one bench alternated between an archived base revision and this tree, its `key=number` rows read into medians and ratios |
| [`evidence/`](evidence/) | The evidence record `ci/gates.sh` writes for every run: commit, checkout state, submodule revisions, toolchain pins, host, and each gate's exit and duration |
| [`c-abi/`](c-abi/) | Operator scripts and JSON fixtures for C-ABI resolve |
| [`fuzz/`](fuzz/) | Fuzz driver and the patched Zig test runner described in [`PROVENANCE.md`](../PROVENANCE.md) |
| [`wasm/`](wasm/) | Deno checks for the browser binding's wasm32 Host (layout descriptor, import set) |
| [`consumer/`](consumer/) | A throwaway downstream package that depends on glowcap the way the README says to, so `zig build consumer-check` tests that first instruction |
| [`deps/`](deps/) | Fetch scripts for pinned third-party sources the build vendors (Mbed TLS) |
| [`run-with-timeout.py`](run-with-timeout.py) | Portable wall-clock deadline for check commands (GNU `timeout` is not on macOS) |

Product code belongs in [`apps/`](../apps/) or [`cli/`](../cli/).

An operation lives where the thing it acts on lives:

- A command against the toolchain is a `zig build` step.
- The installed glowcap CLI owns host installation and Rooms deployment.
- Compose templates and the image recipe stay beside the Rooms deployable.
- Container scripts stay under `.devcontainer/`, agent workflow under
  `.agents/`, and a maintainer's machine and account facts in gitignored
  tooling under `.local/`.

[ADR-0032](../docs/decisions/adr/ADR-0032-cli-and-product-boundaries.md)
records the layout, script placement and lifecycle, the CLI installation, and
the Rooms deployment boundary.
