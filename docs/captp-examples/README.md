# pancake — OCapN protocol diagrams

A dissection of OCapN / CapTP into small Mermaid diagrams: one transaction
shape or state flow per diagram. The authority for every diagram is the
[OCapN draft specifications](https://github.com/ocapn/ocapn/tree/main/draft-specifications)
(CapTP, Model, Locators) and, where flagged, Spritely Goblins's wire behavior.
Rust pancake is prior art, not the oracle; nothing here cites Rust internals.

## Conventions

- **One concern per diagram.** If a diagram needs a legend, split it.
- **Protocol vocabulary only.** Diagrams speak `op:*` / `desc:*` / role names.
  Implementation type names stay out; the Zig code maps onto this vocabulary,
  not the other way around.
- **Spec anchor on every diagram.** Each diagram names the CapTP / Locators
  section it renders. Goblins-canonical extensions (not yet in the draft spec)
  are flagged `[goblins-canonical]`.
- **Mermaid kinds:** `sequenceDiagram` for transactions, `stateDiagram-v2` for
  lifecycles, `flowchart` for structure and validation decisions. No styling
  directives.
- **Living-state surface.** When an op's semantics change — upstream spec or
  the Zig implementation — the matching diagram updates in the same change.
  A diagram claiming behavior the session doesn't enforce is drift.

## Catalog

| File | Diagrams | Covers |
| --- | --- | --- |
| [01-session-lifecycle.md](01-session-lifecycle.md) | SL-1 … SL-6 | Session state machine, `op:start-session`, crossed hellos, admission policy, `op:abort` teardown |
| [02-deliver-and-resolve.md](02-deliver-and-resolve.md) | DR-1 … DR-7 | `op:deliver`, `op:deliver-only`, `op:resolve`, resolver callbacks, bootstrap `fetch`, `op:get` / `op:index` |
| [03-promises-and-pipelining.md](03-promises-and-pipelining.md) | PP-1 … PP-7 | Promise lifecycle, pipelined delivers, multi-hop chains, resolved-answer forwarding, `op:listen` |
| [04-references-and-tables.md](04-references-and-tables.md) | RT-1 … RT-4 | Descriptor taxonomy, perspective flip, the four tables, import installation |
| [05-gc.md](05-gc.md) | GC-1 … GC-4 | Export refcount lifecycle, `op:gc-exports` wire-deltas, the GC race, `op:gc-answers` |
| [06-handoffs.md](06-handoffs.md) | HO-1 … HO-8 | Three-party handoff roles, certificates, per-role validation, replay protection, deposit/withdraw ordering |
| [07-sturdyrefs-and-locators.md](07-sturdyrefs-and-locators.md) | ST-1 … ST-3 | Sturdyref anatomy, enlivenment, equality-driven dedup |

39 diagrams total. The numbering is stable: a conformance scenario, doc
comment, or commit message can cite `HO-7` and mean exactly one validation
flow.
