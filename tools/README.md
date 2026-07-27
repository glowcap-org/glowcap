# tools/

Maintainer-only surface. The usual verification verbs in this repository are
`test/`, `check`, and `gen`: correctness scenarios stay at top-level
[`test/`](../test/); build checks and codegen live here as peer families.

| Path | Owns |
|------|------|
| [`check/`](check/) | Build checks and hygiene (`arch_check`, `meta_check`) |
| [`gen/`](gen/) | Header and binding generators, shared verify/emit harness |
| [`c-abi/`](c-abi/) | Operator scripts and JSON fixtures for C-ABI resolve |
| [`fuzz/`](fuzz/) | The `zig build fuzz` driver and the vendored Zig test runner it patches (see [`PROVENANCE.md`](../PROVENANCE.md)) |
| [`wasm/`](wasm/) | Deno checks for the browser binding's wasm32 Host (layout descriptor, import set) |
| [`run-with-timeout.py`](run-with-timeout.py) | Portable wall-clock deadline for gate commands (GNU `timeout` is not on macOS) |

Product apps do not live here. First-party binaries go under
[`apps/`](../apps/) or [`cli/`](../cli/); demos go under
[`apps/`](../apps/).

Layout decision: [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md).
