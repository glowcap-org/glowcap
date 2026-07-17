# Observability family (Spec B)

Status: active plan

Four observability planes for pancake. Day-one is CapTP introspection plus
stderr logs from the CLI. Timeline viz and OTEL are deferred. Companion:
[ADR-0084](../decisions/adr/ADR-0084-pancake-cli-product-boundary.md)
(product CLI boundary; Spec B is deferred from A-v1).

## Four planes (do not collapse)

| Plane | Job | Day-one | Later |
|-------|-----|---------|-------|
| CapTP introspection | Tables, vows, abort, doctor | yes (`info` only) | full introspect tier when verbs earn distinct views |
| stderr structured logs | Ops without a collector | yes | — |
| Protocol timeline | Topology and message flight (griddle into ocapnviz) | no | yes, plus optional live producer |
| OpenTelemetry | OTLP spans and metrics for APM | no | thin exporter off the same spine |

## Timeline products (deferred)

Prior art lived under the old Rust tree as sibling auxiliary tooling:

```text
griddle-net | extract-ocapn | griddle-render-bridge  --ws-->  ocapnviz
```

| Piece | Role |
|-------|------|
| griddle | Deterministic sim / TCP tap; timeline NDJSON |
| render-bridge | Websocket relay |
| ocapnviz | Browser topology visualizer (Deno/Pixi) |

**CLI brand:** argv[0] is `pancake`. The sim/timeline family is the subtree
`pancake griddle` (status/help placeholder today; runtime deferred). CapTP stays
`pancake ocapn` / `pancake repl`. Optional later: `griddle` shim → `pancake griddle`.

pancake is not ocapnviz's core server; the render-bridge is. Optional later:
`pancake ocapn trace --ws` as a second producer of the shared timeline schema
for live CapTP. Flecs (or equivalent) holds the topology world on the
griddle→viz path; Pixi draws a LOD subset. Native griddle is the power path;
WASM-in-Worker is a demo path.

## OpenTelemetry (deferred)

Adapter-only OTLP export from the same Host and session event spine that powers
stderr logs. Enable with `OTEL_*` or flags; off by default; zero-cost when
disabled. Span names follow CapTP verbs (`ocapn.dial`, `ocapn.call`, and so
on). There is no `pancake otel` command tree. Never in `core = true`.

## Present boundary

OTEL export, griddle **runtime**, ocapnviz, and live timeline WS are not
implemented. `pancake griddle status` exists as a brand placeholder. A-v1 ships
stderr logging and CapTP introspection only.
