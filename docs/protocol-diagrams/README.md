# OCapN protocol diagrams

These pages draw OCapN and CapTP one transaction or state change at a time.
Start with the topic you need. The diagram IDs are stable, so tests and design
notes can cite one directly.

The [OCapN draft specifications](https://github.com/ocapn/ocapn/tree/main/draft-specifications)
are the main source. Diagrams marked `[goblins-canonical]` show behavior from a
live Spritely Goblins peer where the draft has not caught up. Diagrams marked
`[glowcap-next]` show glowcap's negotiated prototype vocabulary
([ADR-0036](../decisions/adr/ADR-0036-identity-and-multihome-routing.md)). The
pinned draft does not specify it, and a baseline session never sees it.

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
| [01-session-lifecycle.md](01-session-lifecycle.md)             | SL-*       | Session state machine, `op:start-session`, crossed hellos, admission policy, `op:abort` teardown                      |
| [02-deliver-and-resolve.md](02-deliver-and-resolve.md)         | DR-*       | `op:deliver` (with and without an answer), resolver callbacks, bootstrap `fetch`, `op:get` / `op:index` |
| [03-promises-and-pipelining.md](03-promises-and-pipelining.md) | PP-*       | Promise lifecycle, pipelined delivers, multi-hop chains, resolved-answer forwarding, `op:listen`                      |
| [04-references-and-tables.md](04-references-and-tables.md)     | RT-*       | Descriptor taxonomy, perspective flip, the four tables, import installation                                           |
| [05-gc.md](05-gc.md)                                           | GC-*       | Export refcount lifecycle, `op:gc-exports` wire-deltas, the GC race, `op:gc-answers`                                  |
| [06-handoffs.md](06-handoffs.md)                               | HO-*       | Three-party handoff roles, certificates, per-role validation, replay protection, deposit/withdraw ordering            |
| [07-sturdyrefs-and-locators.md](07-sturdyrefs-and-locators.md) | ST-*       | Sturdyref anatomy, enlivenment, equality-driven dedup                                                                 |
| [08-multihome-routes.md](08-multihome-routes.md)               | MH-*       | `[glowcap-next]` `id` locator anatomy, route-vocabulary negotiation, signed-give lowering, ordered dials, `id` sturdyrefs |
