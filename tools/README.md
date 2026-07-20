# tools/

Maintainer-only surface. The usual verification verbs in this repository are
`test/`, `check`, and `gen`: correctness scenarios stay at top-level
[`test/`](../test/); build checks and codegen live here as peer families.

| Path | Owns |
|------|------|
| [`check/`](check/) | Build checks and hygiene (`arch_check`, `meta_check`) |
| [`gen/`](gen/) | Header and binding generators, shared verify/emit harness |
| [`c-abi/`](c-abi/) | Operator scripts and JSON fixtures for C-ABI resolve |

Product apps do not live here. First-party binaries go under
[`apps/`](../apps/) or [`cli/`](../cli/); demos go under
[`apps/`](../apps/).

Layout decision: [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md).
