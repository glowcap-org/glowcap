---
name: community-review
description: >-
  Preflight pancake for a careful OCapN wire/suite or Spritely Goblins interop
  read: dual independent lenses, concrete citations, synthesize, gate, defer.
  Use before a real community review invite, or when asked to review pancake
  from OCapN or Goblins concerns. Never name or channel real people.
---

# Community review preflight

Find claim↔evidence mismatches and wire/host gaps a careful OCapN or Goblins-facing
read would hit. Distrust the first soft answer when prerelease has waived migration
cost ([prerelease](../../rules/prerelease.md)). Prefer a gate, a sharper boundary, or
a closed Host/codec edge over a longer apology.

**May name:** OCapN, Spritely, Goblins, and their public resources (spec, suite,
institute docs already linked from vision/README).

**Must not name or infer:** real people, “channel \<person\>", or an author roster.
Taste-reference engineer names stay out of scaffolding
([agent-scaffolding](../../rules/agent-scaffolding.md)). Speak of neighbors with
respect ([doc-voice](../../rules/doc-voice.md)).

## The loop

1. **SCOPE.** Fault / ideal / false constraint — one sentence each.
2. **REVIEW WITH TWO INDEPENDENT LENSES.** Spawn two subagents on the real tree.
   Each gets one lens below. Order both: read code and docs; be honest where already
   right; invent no nits; propose, do not edit (unless the user asked to execute).
3. **SYNTHESIZE.** Where they agree, keep the candidate. Where they disagree, decide
   and say why. If both call a real defect, escalate it.
4. **EXECUTE** only when the user asked for implementation.
5. **GATE.** `zig build check` is authority (exit code, not skimmed output).
6. **DEFER HONESTLY.** Name non-moves with real reasons; park them on
   [`docs/roadmap.md`](../../../docs/roadmap.md) or
   [`docs/boundaries.md`](../../../docs/boundaries.md).

Live CapTP demonstration (call/host/probe a peer while reviewing):
in-host MCP → [pancake-mcp](../pancake-mcp/SKILL.md); shell listen/REPL →
[pancake-cli](../pancake-cli/SKILL.md) — not a throwaway Zig dialer.

## Lenses

### `ocapn-wire`

Review as someone steeped in the public OCapN protocol materials and suite, not as
any named person.

**Cares about:** CapTP wire semantics; upstream suite modules pancake runs; oracle
arms; claim scope matching evidence; session / GC / handoff / sturdyref / passable
edges; [`SECURITY.md`](../../../SECURITY.md) invariants.

**Loads:**
- [`conformance/ocapn-conformance/`](../../../conformance/ocapn-conformance/)
- [`conformance/ocapn-spec/`](../../../conformance/ocapn-spec/)
- [`test/oracle/`](../../../test/oracle/)
- [`docs/boundaries.md`](../../../docs/boundaries.md), [`docs/shipped.md`](../../../docs/shipped.md)
- ADRs 0003, 0006, 0008, 0009/0056, 0012, 0046, 0083 under
  [`docs/decisions/adr/`](../../../docs/decisions/adr/)
- Public OCapN entry points already cited in-repo (e.g.
  [github.com/ocapn/ocapn](https://github.com/ocapn/ocapn))

**Out of scope:** Zig taste, C ABI ergonomics, scale theater — unless they change a
wire claim.

### `goblins-interop`

Review as someone steeped in public [Spritely Goblins](https://spritely.institute/goblins/)
as the practical wire reference, not as any named person.

**Cares about:** bidirectional live conversation on authenticated Syrup/TCP; no
invented wire Goblins cannot speak; handoff / bootstrap / sturdyref / listen honesty;
actor layer above CapTP without redefining CapTP.

**Loads:**
- [`docs/vision.md`](../../../docs/vision.md)
- [`interop/`](../../../interop/)
- [`conformance/goblins-peer/`](../../../conformance/goblins-peer/)
- Live gate inventory in shipped / `build.zig` (`goblins-interop`, `goblins-handoff`,
  binding variants)
- ADRs 0003, 0035, 0056, 0063; boundaries on Null, untag, iroh, bootstrap
- Public Spritely / Goblins resources already cited in-repo

**Out of scope:** Cap’n Proto and iroh except when first-read prose blurs them into
the Goblins interop claim.

## Concrete output each lens must produce

Prioritized, most-impactful first:

- exact path (and line when code),
- before→after or deletion,
- principle served,
- blast radius,
- hard split: `do-now` / `own-pass` / `watch-upstream`.

Synthesize into remediations tagged `invite-blocking` | `packet-honesty` |
`roadmap-watch`. Human-facing summary for invite prep lives in
[`docs/community-review.md`](../../../docs/community-review.md) when that page exists.

## On this codebase

- **Gate:** `zig build check`. Focused: `zig build test`, `arch-check`, `meta-check`,
  `oracle-check`; live `ocapn-conformance`, `goblins-interop`, `goblins-handoff`.
- **Layer bans:** `build.zig` `layer_table` + `arch-check` (`core = true` bans `std.Io`).
- **Prerelease posture:** [`.agents/rules/prerelease.md`](../../rules/prerelease.md).
- **Settled architecture:** [`docs/decisions/adr/`](../../../docs/decisions/adr/).
