# tools/

These are maintainer tools, not product APIs. Correctness scenarios stay in
top-level [`test/`](../test/); checks, generators, and operator scripts live
here.

| Path | Owns |
|------|------|
| [`check/`](check/) | Build checks and hygiene (`arch_check`, `meta_check`) |
| [`gen/`](gen/) | Header and binding generators, shared verify/emit harness |
| [`c-abi/`](c-abi/) | Operator scripts and JSON fixtures for C-ABI resolve |
| [`fuzz/`](fuzz/) | Fuzz driver and the patched Zig test runner described in [`PROVENANCE.md`](../PROVENANCE.md) |
| [`wasm/`](wasm/) | Deno checks for the browser binding's wasm32 Host (layout descriptor, import set) |
| [`run-with-timeout.py`](run-with-timeout.py) | Portable wall-clock deadline for check commands (GNU `timeout` is not on macOS) |

Product code belongs in [`apps/`](../apps/) or [`cli/`](../cli/).

See [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md)
for the layout decision.
