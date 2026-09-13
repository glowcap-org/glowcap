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
against the toolchain is a `zig build` step. A command an operator runs
against a shipped deployable is one front beside that deployable, such as
[`apps/rooms/web/deploy/ops`](../apps/rooms/web/deploy/ops). Container
scripts stay under `.devcontainer/`, agent workflow under `.agents/`, and a
maintainer's machine and account facts in gitignored tooling under `.local/`.

See [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md)
for the layout decision and
[ADR-0150](../docs/decisions/adr/ADR-0150-operations-fronts-and-script-placement.md)
for script placement and lifecycle.
