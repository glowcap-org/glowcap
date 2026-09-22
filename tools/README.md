# tools/

These are maintainer tools, not product APIs. Correctness scenarios stay in
top-level [`test/`](../test/); checks, generators, and operator scripts live
here.

| Path | Owns |
|------|------|
| [`build/`](build/) | Step-registration modules the root `build.zig` composes: shared helpers plus one module per extracted step family |
| [`check/`](check/) | Build checks and hygiene (`arch_check`, `source_check`) |
| [`gen/`](gen/) | Header and binding generators, shared verify/emit harness |
| [`c-abi/`](c-abi/) | Operator scripts and JSON fixtures for C-ABI resolve |
| [`fuzz/`](fuzz/) | Fuzz driver and the patched Zig test runner described in [`PROVENANCE.md`](../PROVENANCE.md) |
| [`wasm/`](wasm/) | Deno checks for the browser binding's wasm32 Host (layout descriptor, import set) |
| [`consumer/`](consumer/) | A throwaway downstream package that depends on glowcap the way the README says to, so `zig build consumer-check` keeps that first instruction a checked claim |
| [`deps/`](deps/) | Fetch scripts for pinned third-party sources the build vendors (Mbed TLS) |
| [`run-with-timeout.py`](run-with-timeout.py) | Portable wall-clock deadline for check commands (GNU `timeout` is not on macOS) |

Product code belongs in [`apps/`](../apps/) or [`cli/`](../cli/).

An operation is placed by what it acts on, not here by default. A command
against the toolchain is a `zig build` step. The installed glowcap CLI owns
host installation and Rooms deployment, while Compose templates and the image
recipe stay beside the Rooms deployable. Container scripts stay under
`.devcontainer/`, agent workflow under `.agents/`, and a maintainer's machine
and account facts in gitignored tooling under `.local/`.

See [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md)
for the layout decision and
[ADR-0150](../docs/decisions/adr/ADR-0150-operations-fronts-and-script-placement.md)
for historical script placement and lifecycle. [ADR-0175](../docs/decisions/adr/ADR-0175-product-installation-and-rooms-deployment.md)
owns the current CLI installation and Rooms deployment boundary.
