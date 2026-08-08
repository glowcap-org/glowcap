# OCapN protocol diagrams

These pages draw OCapN and CapTP one transaction or state change at a time.
Start with the topic you need; the diagram IDs are stable, so tests and design
notes can cite one directly.

The [OCapN draft specifications](https://github.com/ocapn/ocapn/tree/main/draft-specifications)
are the main source. Diagrams marked `[goblins-canonical]` show behavior from a
live Spritely Goblins peer where the draft has not caught up.

## Conventions

- Protocol names (`op:*`, `desc:*`, and role names), not Zig type names.
- One concern per diagram.
- The relevant specification sections linked from each page.
- `sequenceDiagram` for transactions, `stateDiagram-v2` for lifecycles, and
  `flowchart` for structure or validation.

When protocol behavior changes, update the matching diagram in the same
change. A diagram that disagrees with the session is a bug.

## Catalog

| File                                                           | Diagrams    | Covers                                                                                                                |
| -------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------- |
| [01-session-lifecycle.md](01-session-lifecycle.md)             | SL-1 … SL-6 | Session state machine, `op:start-session`, crossed hellos, admission policy, `op:abort` teardown                      |
| [02-deliver-and-resolve.md](02-deliver-and-resolve.md)         | DR-1 … DR-7 | `op:deliver` (with and without an answer), resolver callbacks, bootstrap `fetch`, `op:get` / `op:index` |
| [03-promises-and-pipelining.md](03-promises-and-pipelining.md) | PP-1 … PP-7 | Promise lifecycle, pipelined delivers, multi-hop chains, resolved-answer forwarding, `op:listen`                      |
| [04-references-and-tables.md](04-references-and-tables.md)     | RT-1 … RT-4 | Descriptor taxonomy, perspective flip, the four tables, import installation                                           |
| [05-gc.md](05-gc.md)                                           | GC-1 … GC-4 | Export refcount lifecycle, `op:gc-exports` wire-deltas, the GC race, `op:gc-answers`                                  |
| [06-handoffs.md](06-handoffs.md)                               | HO-1 … HO-8 | Three-party handoff roles, certificates, per-role validation, replay protection, deposit/withdraw ordering            |
| [07-sturdyrefs-and-locators.md](07-sturdyrefs-and-locators.md) | ST-1 … ST-3 | Sturdyref anatomy, enlivenment, equality-driven dedup                                                                 |
